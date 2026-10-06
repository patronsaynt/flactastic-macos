import Foundation
import Observation

/// A place the player bar can send audio to.
struct SpeakerDevice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// UPnP/DLNA renderer, keyed by UDN. Pulls the original file.
        case dlna(udn: String)
        /// AirPlay receiver exposed by macOS as a Core Audio device.
        case airPlay(uid: String)
    }

    let id: String
    let name: String
    let kind: Kind
    let detail: String?

    var isAirPlay: Bool {
        if case .airPlay = kind { return true }
        return false
    }
}

/// Discovers network speakers and owns the active streaming session.
///
/// Two routes:
/// - **DLNA** — `DLNARendererSession` drives the renderer while
///   `PlayerEngine` runs in remote mode; the renderer fetches tracks from
///   `MediaHTTPServer`. Lossless, hi-res, buffered on the device.
/// - **AirPlay** — a session-only output override on `AudioOutputManager`;
///   the normal local graph renders into the AirPlay Core Audio device.
@Observable
@MainActor
final class CastManager {
    private(set) var renderers: [String: DiscoveredRenderer] = [:]
    private(set) var isSearching = false
    private(set) var connectingID: String?
    private(set) var activeDLNAID: String?
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var activeCapabilities: RendererCapabilities?
    /// macOS is refusing our discovery traffic — almost always a denied
    /// Local Network permission (it's re-asked whenever the app's signature
    /// changes, e.g. after a rebuild).
    private(set) var isLocalNetworkBlocked = false

    struct DiscoveredRenderer: Equatable, Sendable {
        let description: UPnPRendererDescription
        let location: URL
        var lastSeen: Date
    }

    @ObservationIgnored private let player: PlayerState
    @ObservationIgnored private let audioOutput: AudioOutputManager
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private var discovery: SSDPDiscovery?
    @ObservationIgnored private var fetching: Set<String> = []
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var session: DLNARendererSession?
    @ObservationIgnored private let server = MediaHTTPServer()
    @ObservationIgnored private let preparer = StreamPreparer()
    @ObservationIgnored private let soap = UPnPSOAPClient(timeout: 4)
    /// Set when the system AirPlay picker closes, so the AirPlay device that
    /// appears next can be adopted even if a specific output is pinned.
    @ObservationIgnored private var awaitingAirPlayRouteUntil: Date?

    /// Renderers not seen for this long drop out of the list.
    static let staleAfter: TimeInterval = 120

    init(player: PlayerState, audioOutput: AudioOutputManager, settings: Settings) {
        self.player = player
        self.audioOutput = audioOutput
        self.settings = settings
        audioOutput.onHardwareChange = { [weak self] in self?.handleHardwareChange() }
    }

    // MARK: - Derived state

    /// Visible speakers, DLNA first. An AirPlay receiver that is also a
    /// discovered DLNA renderer (same name) is folded into the DLNA entry,
    /// which streams at higher quality — unless it's the active route.
    var speakers: [SpeakerDevice] {
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        let dlna = renderers.values
            .filter { $0.lastSeen >= cutoff || "dlna:\($0.description.udn)" == activeDLNAID }
            .map { renderer -> SpeakerDevice in
                let d = renderer.description
                let detail = [d.manufacturer, d.modelName].compactMap { $0 }.joined(separator: " ")
                return SpeakerDevice(id: "dlna:\(d.udn)", name: d.friendlyName, kind: .dlna(udn: d.udn),
                                     detail: detail.isEmpty ? nil : detail)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let dlnaNames = Set(dlna.map { $0.name.lowercased() })
        let activeAirPlay = activeAirPlayDevice?.uid
        let airPlay = audioOutput.devices
            .filter { $0.isAirPlay && (!dlnaNames.contains($0.name.lowercased()) || $0.uid == activeAirPlay) }
            .map { SpeakerDevice(id: "airplay:\($0.uid)", name: $0.name, kind: .airPlay(uid: $0.uid), detail: "AirPlay") }
        return dlna + airPlay
    }

    /// The AirPlay device the local graph is currently rendering into.
    var activeAirPlayDevice: AudioOutputDevice? {
        guard activeDLNAID == nil, let device = audioOutput.effectiveDevice, device.isAirPlay else { return nil }
        return device
    }

    var activeSpeakerID: String? {
        activeDLNAID ?? activeAirPlayDevice.map { "airplay:\($0.uid)" }
    }

    var activeSpeaker: SpeakerDevice? {
        guard let id = activeSpeakerID else { return nil }
        return speakers.first { $0.id == id }
    }

    /// True while a network device (not the local graph) is playing.
    var isStreamingRemotely: Bool { activeDLNAID != nil }

    /// Whether the volume slider can do anything right now.
    var isVolumeControllable: Bool { session.map(\.supportsVolume) ?? true }

    /// The local output shown as "This Mac".
    var localDevice: AudioOutputDevice? {
        if let device = audioOutput.effectiveDevice, !device.isAirPlay { return device }
        return fallbackLocalDevice
    }

    /// One-line description of what the active speaker receives.
    var activeQualityDescription: String? {
        if activeAirPlayDevice != nil { return "AirPlay · CD-quality lossless" }
        guard activeDLNAID != nil else { return nil }
        switch settings.networkStreamQuality {
        case .original:
            if let track = player.currentTrack {
                let plan = StreamPlanner.plan(for: track, capabilities: activeCapabilities ?? .unknown,
                                              quality: .original)
                if case .transcode = plan { return "Converted for this speaker" }
            }
            return "Bit-perfect · original file"
        case .hiRes96: return "Lossless · up to 24-bit / 96 kHz"
        case .cd: return "Lossless · 16-bit / 44.1 kHz"
        }
    }

    // MARK: - Discovery

    /// Called while the speaker picker is open: search now and every 15 s.
    func beginBrowsing() {
        browseTask?.cancel()
        browseTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.search()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func endBrowsing() {
        browseTask?.cancel()
        browseTask = nil
    }

    private func search() {
        if discovery == nil {
            discovery = SSDPDiscovery(
                onMessage: { [weak self] message in
                    Task { @MainActor in self?.handle(message) }
                },
                onSendResult: { [weak self] blocked in
                    Task { @MainActor in
                        guard let self, self.isLocalNetworkBlocked != blocked else { return }
                        self.isLocalNetworkBlocked = blocked
                    }
                }
            )
        }
        discovery?.search()
        isSearching = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.isSearching = false
        }
    }

    private func handle(_ message: SSDPMessage) {
        let udn = message.deviceUDN
        if message.isByeBye {
            if "dlna:\(udn)" != activeDLNAID { renderers[udn] = nil }
            return
        }
        guard let location = message.location else { return }
        if var existing = renderers[udn], existing.location == location {
            existing.lastSeen = Date()
            renderers[udn] = existing
            return
        }
        guard !fetching.contains(udn) else { return }
        fetching.insert(udn)
        Task { [weak self] in
            defer { self?.fetching.remove(udn) }
            var request = URLRequest(url: location)
            request.timeoutInterval = 4
            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(for: request)
            } catch {
                castLog.error("description fetch failed for \(location.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let description = UPnPRendererDescription.parse(data, location: location) else {
                castLog.notice("ignoring \(location.absoluteString, privacy: .public): not a playable renderer")
                return
            }
            castLog.notice("found \(description.friendlyName, privacy: .public) at \(location.absoluteString, privacy: .public)")
            self?.renderers[udn] = DiscoveredRenderer(description: description, location: location, lastSeen: Date())
        }
    }

    // MARK: - Connecting

    func select(_ speaker: SpeakerDevice) {
        guard speaker.id != activeSpeakerID, speaker.id != connectingID else { return }
        errorMessage = nil
        switch speaker.kind {
        case .airPlay(let uid):
            connectTask?.cancel()
            connectingID = nil
            // Route the local graph first so detaching resumes on AirPlay.
            audioOutput.setOverrideDevice(uid: uid)
            endDLNASession(resumePlaying: true)
        case .dlna(let udn):
            guard let renderer = renderers[udn]?.description else { return }
            connectingID = speaker.id
            connectTask?.cancel()
            connectTask = Task { [weak self] in await self?.connect(renderer, id: speaker.id) }
        }
    }

    /// Back to the Mac's own output.
    func selectThisMac() {
        errorMessage = nil
        connectTask?.cancel()
        connectingID = nil
        if audioOutput.effectiveDevice?.isAirPlay == true {
            // Override with the local device so leaving AirPlay works even
            // when the system default itself is the AirPlay receiver.
            audioOutput.setOverrideDevice(uid: fallbackLocalDevice?.uid)
        } else if audioOutput.overrideDeviceUID != nil {
            audioOutput.setOverrideDevice(uid: nil)
        }
        endDLNASession(resumePlaying: true)
    }

    /// The system AirPlay picker was dismissed: adopt the AirPlay route it
    /// creates for a few seconds, even if a specific output is pinned.
    func airPlayPickerDidClose() {
        awaitingAirPlayRouteUntil = Date().addingTimeInterval(15)
        handleHardwareChange()
    }

    private func connect(_ renderer: UPnPRendererDescription, id: String) async {
        do {
            let port = try await server.start()
            guard let host = renderer.avTransportURL.host,
                  let local = NetworkInterfaces.localAddress(toward: host),
                  let baseURL = URL(string: "http://\(local):\(port)") else {
                throw UPnPError(code: nil, message: "No network route to \(renderer.friendlyName)")
            }

            var capabilities = RendererCapabilities.unknown
            if let url = renderer.connectionManagerURL,
               let values = try? await soap.call("GetProtocolInfo", service: UPnPRendererDescription.connectionManagerType, url: url),
               let sink = values["Sink"] {
                capabilities = RendererCapabilities.parse(sink: sink)
            }

            // Ask up front instead of probing: some renderers sit on an
            // action they don't implement until it times out, stalling every
            // command queued behind it.
            var supportsSetNext = true
            if let scpd = renderer.avTransportSCPDURL {
                var request = URLRequest(url: scpd)
                request.timeoutInterval = 4
                if let (data, _) = try? await URLSession.shared.data(for: request) {
                    let actions = UPnPRendererDescription.actionNames(inSCPD: data)
                    if !actions.isEmpty { supportsSetNext = actions.contains("SetNextAVTransportURI") }
                }
            }
            castLog.notice("connecting to \(renderer.friendlyName, privacy: .public): gapless next \(supportsSetNext ? "supported" : "unsupported", privacy: .public), sink \(capabilities.sinkMimeTypes.sorted().joined(separator: " "), privacy: .public)")

            let newSession = DLNARendererSession(
                renderer: renderer, server: server, preparer: preparer,
                capabilities: capabilities, quality: settings.networkStreamQuality, baseURL: baseURL,
                supportsSetNext: supportsSetNext
            )
            newSession.engine = player.engine
            newSession.onConnectionLost = { [weak self, weak newSession] message in
                guard let self, let newSession, self.session === newSession else { return }
                self.endDLNASession(resumePlaying: false)
                self.errorMessage = message
            }
            newSession.onStatusChange = { [weak self] status in self?.statusMessage = status }

            let volume = await newSession.fetchVolume()
            guard !Task.isCancelled, connectingID == id else { return }

            // DLNA replaces any AirPlay route; the Mac output resumes locally
            // on disconnect.
            if audioOutput.effectiveDevice?.isAirPlay == true {
                audioOutput.setOverrideDevice(uid: fallbackLocalDevice?.uid)
            }

            let previous = session
            session = newSession
            activeCapabilities = capabilities
            player.engine.attachRemote(newSession, volume: volume)
            newSession.startPolling()
            activeDLNAID = id
            connectingID = nil
            if let previous { await previous.close() }
        } catch {
            guard connectingID == id else { return }
            connectingID = nil
            errorMessage = "Couldn't connect to \(renderer.friendlyName)"
            print("[Cast] Connect failed: \(error)")
            if session == nil { server.stop() }
        }
    }

    private func endDLNASession(resumePlaying: Bool) {
        guard let current = session else { return }
        session = nil
        activeDLNAID = nil
        activeCapabilities = nil
        statusMessage = nil
        player.engine.detachRemote(resumePlaying: resumePlaying)
        Task { [weak self] in
            await current.close()
            // A new session may have started while the old one closed.
            guard let self, self.session == nil, self.connectingID == nil else { return }
            self.server.stop()
            await self.preparer.purge()
        }
    }

    // MARK: - AirPlay route tracking

    private func handleHardwareChange() {
        guard let until = awaitingAirPlayRouteUntil else { return }
        guard Date() < until else {
            awaitingAirPlayRouteUntil = nil
            return
        }
        guard let device = audioOutput.defaultDevice, device.isAirPlay else { return }
        awaitingAirPlayRouteUntil = nil
        if audioOutput.effectiveDevice?.uid == device.uid {
            // Already following the system default onto AirPlay.
            endDLNASession(resumePlaying: true)
        } else {
            if let speaker = speakers.first(where: { $0.kind == .airPlay(uid: device.uid) }) {
                select(speaker)
            } else {
                audioOutput.setOverrideDevice(uid: device.uid)
                endDLNASession(resumePlaying: true)
            }
        }
    }

    /// The best non-AirPlay output: the pinned device, else built-in, else any.
    private var fallbackLocalDevice: AudioOutputDevice? {
        let local = audioOutput.devices.filter { !$0.isAirPlay }
        if let uid = settings.outputDeviceUID, let pinned = local.first(where: { $0.uid == uid }) { return pinned }
        if let def = audioOutput.defaultDevice, !def.isAirPlay { return def }
        return local.first(where: \.isBuiltIn) ?? local.first
    }
}
