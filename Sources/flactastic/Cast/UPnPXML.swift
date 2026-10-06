import Foundation

// MARK: - Device description

/// The parts of a UPnP MediaRenderer device description we need to drive it.
struct UPnPRendererDescription: Equatable, Sendable {
    let udn: String
    let friendlyName: String
    let manufacturer: String?
    let modelName: String?
    let avTransportURL: URL
    let renderingControlURL: URL?
    let connectionManagerURL: URL?
    /// The AVTransport service description, listing the actions it implements.
    var avTransportSCPDURL: URL? = nil

    static let avTransportType = "urn:schemas-upnp-org:service:AVTransport:1"
    static let renderingControlType = "urn:schemas-upnp-org:service:RenderingControl:1"
    static let connectionManagerType = "urn:schemas-upnp-org:service:ConnectionManager:1"

    /// Parses a device description fetched from `location`. Returns nil for
    /// devices without an AVTransport service (nothing we can play on).
    static func parse(_ data: Data, location: URL) -> UPnPRendererDescription? {
        let collector = DescriptionCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return nil }

        let base = collector.urlBase.flatMap(URL.init(string:)) ?? location
        func service(_ type: String) -> DescriptionCollector.Service? {
            // Match on the service family, ignoring the version suffix.
            let family = type.components(separatedBy: ":").dropLast().joined(separator: ":")
            return collector.services.first { $0.type.hasPrefix(family) }
        }
        func controlURL(_ type: String) -> URL? {
            service(type).flatMap { URL(string: $0.controlURL, relativeTo: base)?.absoluteURL }
        }

        guard let transport = controlURL(avTransportType),
              let udn = collector.fields["UDN"] else { return nil }
        return UPnPRendererDescription(
            udn: udn,
            friendlyName: collector.fields["friendlyName"] ?? location.host ?? "Speaker",
            manufacturer: collector.fields["manufacturer"],
            modelName: collector.fields["modelName"],
            avTransportURL: transport,
            renderingControlURL: controlURL(renderingControlType),
            connectionManagerURL: controlURL(connectionManagerType),
            avTransportSCPDURL: service(avTransportType).flatMap {
                $0.scpdURL.isEmpty ? nil : URL(string: $0.scpdURL, relativeTo: base)?.absoluteURL
            }
        )
    }

    /// Action names declared by a service description (SCPD) document.
    static func actionNames(inSCPD data: Data) -> Set<String> {
        let collector = ActionCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector.names
    }

    private final class ActionCollector: NSObject, XMLParserDelegate {
        var names: Set<String> = []
        private var stack: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            stack.append(localName(elementName))
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            // <action><name>…</name> — not argument names, which nest deeper.
            if stack.count >= 2, stack[stack.count - 1] == "name", stack[stack.count - 2] == "action" {
                names.insert(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            stack.removeLast()
            text = ""
        }
    }

    private final class DescriptionCollector: NSObject, XMLParserDelegate {
        struct Service { var type = ""; var controlURL = ""; var scpdURL = "" }

        /// First value seen for each device field — the root device's, since
        /// it precedes any embedded devices in document order.
        var fields: [String: String] = [:]
        var services: [Service] = []
        var urlBase: String?

        private var text = ""
        private var currentService: Service?
        private static let deviceFields: Set<String> = ["friendlyName", "manufacturer", "modelName", "UDN"]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            text = ""
            if localName(elementName) == "service" { currentService = Service() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let name = localName(elementName)
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "service":
                if let service = currentService, !service.controlURL.isEmpty { services.append(service) }
                currentService = nil
            case "serviceType":
                currentService?.type = value
            case "controlURL":
                currentService?.controlURL = value
            case "SCPDURL":
                currentService?.scpdURL = value
            case "URLBase":
                if !value.isEmpty { urlBase = value }
            default:
                if Self.deviceFields.contains(name), fields[name] == nil, !value.isEmpty {
                    fields[name] = value
                }
            }
            text = ""
        }
    }
}

// MARK: - SOAP

enum UPnPSOAP {

    /// A SOAP request body for `action` on `serviceType`.
    static func envelope(action: String, serviceType: String, arguments: [(String, String)]) -> Data {
        let args = arguments.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(serviceType)">\(args)</u:\(action)></s:Body>\
        </s:Envelope>
        """
        return Data(xml.utf8)
    }

    /// Leaf element values of a response (or fault), keyed by local name.
    /// UPnP action responses are flat, so this is all the structure we need.
    static func leafValues(_ data: Data) -> [String: String] {
        let collector = LeafCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        _ = parser.parse()
        return collector.values
    }

    static func xmlEscape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for ch in string {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    private final class LeafCollector: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private var text = ""
        private var hadChild = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            text = ""
            hadChild = false
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if !hadChild {
                values[localName(elementName)] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            hadChild = true
            text = ""
        }
    }
}

/// The device answered, but with an error (SOAP fault or HTTP error status).
/// Network failures surface as `URLError` instead, which is how sessions tell
/// "rejected this command" apart from "unreachable".
struct UPnPError: Error, LocalizedError {
    /// UPnP error code from a SOAP fault (e.g. 401 Invalid Action), when given.
    let code: Int?
    let message: String

    var errorDescription: String? { message }
}

/// Minimal UPnP control point: one SOAP POST per action.
struct UPnPSOAPClient: Sendable {
    private let session: URLSession

    init(timeout: TimeInterval = 5) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config)
    }

    @discardableResult
    func call(_ action: String, service: String, url: URL,
              _ arguments: [(String, String)] = []) async throws -> [String: String] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = UPnPSOAP.envelope(action: action, serviceType: service, arguments: arguments)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let values = UPnPSOAP.leafValues(data)
        guard (200..<300).contains(status) else {
            throw UPnPError(
                code: values["errorCode"].flatMap(Int.init),
                message: values["errorDescription"] ?? "\(action) failed (HTTP \(status))"
            )
        }
        return values
    }
}

// MARK: - DIDL-Lite

/// Track metadata in the DIDL-Lite form renderers show on their displays.
enum DIDLLite {

    /// DLNA flags: byte-seek supported (OP=01), streaming transfer, background
    /// transfer, connection stalling allowed, DLNA v1.5.
    static let dlnaFeatures = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

    static func protocolInfo(mimeType: String) -> String {
        "http-get:*:\(mimeType):\(dlnaFeatures)"
    }

    struct Resource {
        var url: URL
        var mimeType: String
        var size: Int64?
        var duration: TimeInterval?
        var sampleRate: Double?
        var bitDepth: Int?
        var channels: Int?
    }

    static func metadata(for track: Track, resource: Resource, artworkURL: URL?) -> String {
        let e = UPnPSOAP.xmlEscape
        var item = "<dc:title>\(e(track.title))</dc:title>"
        item += "<upnp:class>object.item.audioItem.musicTrack</upnp:class>"
        if let artist = track.artist {
            item += "<dc:creator>\(e(artist))</dc:creator><upnp:artist>\(e(artist))</upnp:artist>"
        }
        if let albumArtist = track.albumArtist {
            item += "<upnp:artist role=\"AlbumArtist\">\(e(albumArtist))</upnp:artist>"
        }
        if let album = track.album { item += "<upnp:album>\(e(album))</upnp:album>" }
        if let number = track.trackNumber { item += "<upnp:originalTrackNumber>\(number)</upnp:originalTrackNumber>" }
        if let genre = track.genre { item += "<upnp:genre>\(e(genre))</upnp:genre>" }
        if let artworkURL { item += "<upnp:albumArtURI>\(e(artworkURL.absoluteString))</upnp:albumArtURI>" }

        var attrs = "protocolInfo=\"\(e(protocolInfo(mimeType: resource.mimeType)))\""
        if let size = resource.size { attrs += " size=\"\(size)\"" }
        if let duration = resource.duration { attrs += " duration=\"\(formatTime(duration, millis: true))\"" }
        if let rate = resource.sampleRate { attrs += " sampleFrequency=\"\(Int(rate))\"" }
        if let bits = resource.bitDepth { attrs += " bitsPerSample=\"\(bits)\"" }
        if let channels = resource.channels { attrs += " nrAudioChannels=\"\(channels)\"" }
        item += "<res \(attrs)>\(e(resource.url.absoluteString))</res>"

        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"\(track.id.uuidString)\" parentID=\"0\" restricted=\"1\">\(item)</item></DIDL-Lite>"
    }

    /// `H:MM:SS` (or `H:MM:SS.mmm`), the UPnP time format.
    static func formatTime(_ seconds: TimeInterval, millis: Bool = false) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let base = String(format: "%d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
        guard millis else { return base }
        return base + String(format: ".%03d", Int((clamped - Double(whole)) * 1000))
    }

    /// Parses `H+:MM:SS[.F+]`; nil for `NOT_IMPLEMENTED` and other junk.
    static func parseTime(_ string: String?) -> TimeInterval? {
        guard let string else { return nil }
        let parts = string.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}

private func localName(_ qualified: String) -> String {
    qualified.split(separator: ":").last.map(String.init) ?? qualified
}
