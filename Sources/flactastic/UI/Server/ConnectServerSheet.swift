import AppKit
import SwiftUI

/// Connecting to a FLACtastic Server: pick it (or type its address), check
/// its fingerprint, sign in. The fingerprint is confirmed before any
/// password leaves this Mac (§3).
struct ConnectServerSheet: View {
    @Environment(ServerSession.self) private var server
    @Environment(ListeningStore.self) private var listening
    @Environment(Settings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case pick
        case fingerprint(ServerAddress, name: String, pin: Data)
        case signIn(ServerAddress, name: String, pin: Data)
        case history
    }

    @State private var step: Step = .pick
    @State private var discovery = ServerDiscovery()
    @State private var typed = ""
    @State private var busy = false
    @State private var error: String?
    @State private var info: ServerInfo?
    @State private var username = ""
    @State private var password = ""
    @State private var folder: URL?
    @State private var historyCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                SheetCloseButton { dismiss() }
            }
            Text(title)
                .font(.system(size: 40, weight: .heavy))
                .tracking(-1.5)
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 6)

            Group {
                switch step {
                case .pick: pick
                case .fingerprint(_, _, let pin): fingerprint(pin)
                case .signIn(_, let name, _): signIn(name)
                case .history: history
                }
            }
            .padding(.top, 26)
            .transition(.opacity)

            Spacer(minLength: 16)
            Text(error ?? " ")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.qualityLow)
                .opacity(error == nil ? 0 : 1)
            HStack(spacing: 10) {
                if busy { BrandLoader(height: 22) }
                Spacer()
                actions
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 34)
        .padding(.top, 18)
        .padding(.bottom, 28)
        .frame(width: 560, height: 520)
        .background(Theme.surface)
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.35), value: step)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private var title: String {
        switch step {
        case .pick: "Connect"
        case .fingerprint: "Check the server"
        case .signIn(_, let name, _): name
        case .history: "Your history"
        }
    }

    private var subtitle: String {
        switch step {
        case .pick: "Pick your FLACtastic Server, or type its address."
        case .fingerprint: "Make sure this matches what flactastic-server info shows."
        case .signIn: "Sign in with your account on this server."
        case .history: "Bring this Mac's plays to the server?"
        }
    }

    // MARK: Steps

    private var pick: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(discovery.servers) { found in
                OnboardingOption(icon: "server.rack", title: found.name,
                                 detail: found.isCompatible ? "On this network" : "Needs a newer FLACtastic",
                                 action: "Connect", isProminent: true) {
                    Task { await connect(found) }
                }
                .disabled(!found.isCompatible || busy)
            }
            SheetLabel(text: "Address")
                .padding(.top, discovery.servers.isEmpty ? 0 : 10)
            TextField("nas.local or 192.168.1.20:4410", text: $typed)
                .textFieldStyle(QuietFieldStyle())
                .onSubmit { Task { await connectTyped() } }
        }
    }

    private func fingerprint(_ pin: Data) -> some View {
        Text(ServerPin.display(pin))
            .font(.system(size: 54, weight: .heavy).monospacedDigit())
            .tracking(-1.5)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
    }

    private func signIn(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            boxed(TextField("Username", text: $username))
            boxed(SecureField("Password", text: $password).onSubmit { Task { await signIn() } })
            OnboardingOption(icon: "folder", title: "Offline copies",
                             detail: (folder ?? defaultFolder(name)).path, action: "Change") { chooseFolder(name) }
                .padding(.top, 8)
        }
    }

    private var history: some View {
        OnboardingDoneRow(title: "Signed in", detail: "\(historyCount) plays on this Mac") { EmptyView() }
    }

    @ViewBuilder
    private var actions: some View {
        switch step {
        case .pick:
            Button("Connect") { Task { await connectTyped() } }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .disabled(ServerAddress(typed: typed) == nil || busy)
        case .fingerprint(let address, let name, let pin):
            Button("Cancel") { step = .pick; error = nil }
                .buttonStyle(SheetPillStyle())
            Button("It Matches") { step = .signIn(address, name: name, pin: pin) }
                .buttonStyle(SheetPillStyle(isPrimary: true))
        case .signIn:
            Button("Back") { step = .pick; error = nil }
                .buttonStyle(SheetPillStyle())
            Button("Sign In") { Task { await signIn() } }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .disabled(username.isEmpty || password.utf8.count < 8 || busy)
                .keyboardShortcut(.defaultAction)
        case .history:
            Button("Not Now") { server.history.markOffered(); dismiss() }
                .buttonStyle(SheetPillStyle())
            Button("Bring It") { Task { await bringHistory() } }
                .buttonStyle(SheetPillStyle(isPrimary: true))
                .disabled(busy)
        }
    }

    private func boxed(_ field: some View) -> some View {
        field
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.textPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Actions

    private func connect(_ found: DiscoveredServer) async {
        busy = true
        defer { busy = false }
        guard let address = await ServerDiscovery.resolve(found) else { error = "Can't reach \(found.name)."; return }
        await probe(address)
    }

    private func connectTyped() async {
        guard let address = ServerAddress(typed: typed) else { return }
        busy = true
        defer { busy = false }
        await probe(address)
    }

    private func probe(_ address: ServerAddress) async {
        error = nil
        do {
            let (info, pin) = try await ServerSession.probe(address)
            guard info.isCompatible else { error = "This server needs a newer FLACtastic."; return }
            self.info = info
            let name = TXTRecordCodec.sanitizeDisplayName(info.name, fallback: "FLACtastic Server")
            step = .fingerprint(address, name: name, pin: pin)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Can't reach that address."
        }
    }

    private func signIn() async {
        guard case .signIn(let address, let name, let pin) = step, let info else { return }
        busy = true
        defer { busy = false }
        error = nil
        // Leaving the local library: save its history first.
        listening.save()
        let localRoot = settings.lastRootPath.map { URL(fileURLWithPath: $0) }
        do {
            try await server.signIn(address: address, info: info, pin: pin, username: username,
                                    password: password, offlineFolder: folder ?? defaultFolder(name))
            password = ""
            if let localRoot, server.history.shouldOfferLocalUpload {
                let url = ListeningStore.historyURL(for: localRoot, librariesDirectory: ListeningStore.defaultLibrariesDirectory)
                historyCount = ListeningStore.readHistory(url).0.count
            }
            if historyCount > 0 { step = .history } else { dismiss() }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func bringHistory() async {
        guard let path = settings.lastRootPath else { return dismiss() }
        busy = true
        defer { busy = false }
        do {
            _ = try await server.history.uploadLocal(from: URL(fileURLWithPath: path))
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func defaultFolder(_ name: String) -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        let safe = ImportCopy.sanitize(name)
        return music.appendingPathComponent("FLACtastic", isDirectory: true).appendingPathComponent(safe, isDirectory: true)
    }

    private func chooseFolder(_ name: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Where offline copies go"
        panel.directoryURL = (folder ?? defaultFolder(name)).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
}
