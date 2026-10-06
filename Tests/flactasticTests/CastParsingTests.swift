import Foundation
import Testing
@testable import flactastic

private func track(_ title: String = "Song", format: AudioFileFormat = .flac,
                   rate: Double? = 44_100, bits: Int? = 16) -> Track {
    Track(url: URL(fileURLWithPath: "/music/\(title).\(format.rawValue)"), title: title,
          duration: 200, fileFormat: format, sampleRate: rate, bitDepth: bits)
}

// MARK: - SSDP

@Test func ssdpParsesSearchResponseCaseInsensitively() throws {
    let text = "HTTP/1.1 200 OK\r\n"
        + "cache-control: max-age=1800\r\n"
        + "Location: http://192.168.1.40:49152/description.xml\r\n"
        + "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n"
        + "usn: uuid:abc-123::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
    let message = try #require(SSDPMessage.parse(text))
    #expect(message.location == URL(string: "http://192.168.1.40:49152/description.xml"))
    #expect(message.maxAge == 1800)
    #expect(message.deviceUDN == "uuid:abc-123")
    #expect(!message.isByeBye)
}

@Test func ssdpParsesByeByeWithoutLocation() throws {
    let text = "NOTIFY * HTTP/1.1\r\nNTS: ssdp:byebye\r\nNT: upnp:rootdevice\r\nUSN: uuid:abc-123::upnp:rootdevice\r\n\r\n"
    let message = try #require(SSDPMessage.parse(text))
    #expect(message.isByeBye)
    #expect(message.location == nil)
}

@Test func ssdpRejectsMSearchEchoAndGarbage() {
    #expect(SSDPMessage.parse(SSDPDiscovery.searchRequest()) == nil)
    #expect(SSDPMessage.parse("hello") == nil)
}

// MARK: - Device description

private let descriptionXML = """
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Falco</friendlyName>
    <manufacturer>Andover Audio</manufacturer>
    <modelName>Songbird</modelName>
    <UDN>uuid:abc-123</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/upnp/control/rendercontrol1</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>upnp/control/rendertransport1</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/upnp/control/connectionmanager1</controlURL>
      </service>
    </serviceList>
  </device>
</root>
"""

@Test func parsesRendererDescriptionAndResolvesControlURLs() throws {
    let location = try #require(URL(string: "http://192.168.1.40:49152/description.xml"))
    let desc = try #require(UPnPRendererDescription.parse(Data(descriptionXML.utf8), location: location))
    #expect(desc.friendlyName == "Falco")
    #expect(desc.modelName == "Songbird")
    #expect(desc.udn == "uuid:abc-123")
    #expect(desc.avTransportURL.absoluteString == "http://192.168.1.40:49152/upnp/control/rendertransport1")
    #expect(desc.renderingControlURL?.absoluteString == "http://192.168.1.40:49152/upnp/control/rendercontrol1")
    #expect(desc.connectionManagerURL != nil)
}

@Test func descriptionWithoutAVTransportIsNotARenderer() {
    let xml = "<root><device><friendlyName>NAS</friendlyName><UDN>uuid:x</UDN><serviceList/></device></root>"
    #expect(UPnPRendererDescription.parse(Data(xml.utf8), location: URL(string: "http://10.0.0.2/d.xml")!) == nil)
}

// MARK: - SOAP

@Test func soapResponseLeafValuesIncludeEscapedMetadata() {
    let xml = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
    <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
    <Track>1</Track><TrackDuration>0:03:20</TrackDuration>
    <TrackMetaData>&lt;DIDL-Lite&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>
    <TrackURI>http://192.168.1.5:5000/t/abc.flac</TrackURI><RelTime>0:01:05.250</RelTime>
    </u:GetPositionInfoResponse></s:Body></s:Envelope>
    """
    let values = UPnPSOAP.leafValues(Data(xml.utf8))
    #expect(values["RelTime"] == "0:01:05.250")
    #expect(values["TrackMetaData"] == "<DIDL-Lite></DIDL-Lite>")
    #expect(values["TrackURI"] == "http://192.168.1.5:5000/t/abc.flac")
    #expect(values["GetPositionInfoResponse"] == nil)
}

@Test func soapEnvelopeEscapesArguments() {
    let body = String(decoding: UPnPSOAP.envelope(action: "SetAVTransportURI",
                                                  serviceType: UPnPRendererDescription.avTransportType,
                                                  arguments: [("CurrentURIMetaData", "<a b=\"1\">&</a>")]), as: UTF8.self)
    #expect(body.contains("<CurrentURIMetaData>&lt;a b=&quot;1&quot;&gt;&amp;&lt;/a&gt;</CurrentURIMetaData>"))
    #expect(body.contains("<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
}

// MARK: - DIDL-Lite

@Test func upnpTimeFormatRoundTrips() {
    #expect(DIDLLite.formatTime(3725.5) == "1:02:05")
    #expect(DIDLLite.formatTime(3725.5, millis: true) == "1:02:05.500")
    #expect(DIDLLite.parseTime("1:02:05.500") == 3725.5)
    #expect(DIDLLite.parseTime("0:00:07") == 7)
    #expect(DIDLLite.parseTime("NOT_IMPLEMENTED") == nil)
    #expect(DIDLLite.parseTime(nil) == nil)
}

@Test func didlMetadataEscapesTextAndDescribesResource() {
    var t = track("Rock & <Roll>")
    t.artist = "AC/DC \"Live\""
    let resource = DIDLLite.Resource(url: URL(string: "http://10.0.0.5:5000/t/abc.flac")!, mimeType: "audio/flac",
                                     size: 1234, duration: 200, sampleRate: 96_000, bitDepth: 24, channels: nil)
    let xml = DIDLLite.metadata(for: t, resource: resource, artworkURL: nil)
    #expect(xml.contains("<dc:title>Rock &amp; &lt;Roll&gt;</dc:title>"))
    #expect(xml.contains("AC/DC &quot;Live&quot;"))
    #expect(xml.contains("protocolInfo=\"http-get:*:audio/flac:DLNA.ORG_OP=01;"))
    #expect(xml.contains("sampleFrequency=\"96000\""))
    #expect(xml.contains("bitsPerSample=\"24\""))
    #expect(xml.contains("duration=\"0:03:20.000\""))
    // The DIDL must itself be well-formed XML.
    #expect(XMLParser(data: Data(xml.utf8)).parse())
}

// MARK: - Stream planning

@Test func sinkListParsesMimeTypes() {
    let caps = RendererCapabilities.parse(sink: "http-get:*:audio/x-flac:*,http-get:*:audio/mpeg:DLNA.ORG_PN=MP3, http-get:*:image/jpeg:*")
    #expect(caps.sinkMimeTypes == ["audio/x-flac", "audio/mpeg", "image/jpeg"])
    #expect(caps.acceptsFLAC)
    #expect(!caps.accepts(.aiff))
    #expect(RendererCapabilities.unknown.accepts(.aiff))
}

@Test func originalUsesTheMimeSpellingTheRendererLists() {
    // Linkplay (e.g. Andover Songbird) lists audio/m4a but not audio/mp4.
    let linkplay = RendererCapabilities.parse(sink: "http-get:*:audio/m4a:*,http-get:*:audio/x-flac:*")
    #expect(StreamPlanner.plan(for: track(format: .alac), capabilities: linkplay, quality: .original)
        == .original(mimeType: "audio/m4a"))
    #expect(StreamPlanner.plan(for: track(), capabilities: linkplay, quality: .original)
        == .original(mimeType: "audio/x-flac"))
}

@Test func originalQualityServesHiResFlacUntouched() {
    let plan = StreamPlanner.plan(for: track(rate: 192_000, bits: 24), capabilities: .unknown, quality: .original)
    #expect(plan == .original(mimeType: "audio/flac"))
}

@Test func hiResCapDownsamplesWithinRateFamily() {
    let caps = RendererCapabilities.parse(sink: "http-get:*:audio/flac:*")
    #expect(StreamPlanner.plan(for: track(rate: 192_000, bits: 24), capabilities: caps, quality: .hiRes96)
        == .transcode(container: .flac, sampleRate: 96_000, bitDepth: 24))
    #expect(StreamPlanner.plan(for: track(rate: 176_400, bits: 24), capabilities: caps, quality: .hiRes96)
        == .transcode(container: .flac, sampleRate: 88_200, bitDepth: 24))
    #expect(StreamPlanner.plan(for: track(rate: 96_000, bits: 24), capabilities: caps, quality: .hiRes96)
        == .original(mimeType: "audio/flac"))
}

@Test func cdCapAlwaysTargets44k16() {
    #expect(StreamPlanner.plan(for: track(rate: 48_000, bits: 24), capabilities: .unknown, quality: .cd)
        == .transcode(container: .flac, sampleRate: 44_100, bitDepth: 16))
    #expect(StreamPlanner.plan(for: track(rate: 44_100, bits: 16), capabilities: .unknown, quality: .cd)
        == .original(mimeType: "audio/flac"))
}

@Test func lossyFilesAreNeverReencodedForACap() {
    let mp3 = track(format: .mp3, rate: 48_000, bits: nil)
    #expect(StreamPlanner.plan(for: mp3, capabilities: .unknown, quality: .cd) == .original(mimeType: "audio/mpeg"))
}

@Test func unsupportedFormatIsConvertedToWhatTheRendererTakes() {
    let wavOnly = RendererCapabilities.parse(sink: "http-get:*:audio/wav:*,http-get:*:audio/mpeg:*")
    #expect(StreamPlanner.plan(for: track(format: .aiff, rate: 96_000, bits: 24), capabilities: wavOnly, quality: .original)
        == .transcode(container: .wav, sampleRate: 96_000, bitDepth: 24))
    let flacOnly = RendererCapabilities.parse(sink: "http-get:*:audio/flac:*")
    #expect(StreamPlanner.plan(for: track(format: .alac, rate: 44_100, bits: 16), capabilities: flacOnly, quality: .original)
        == .transcode(container: .flac, sampleRate: 44_100, bitDepth: 16))
}

// MARK: - Networking helpers

@Test func localAddressPrefersRendererSubnet() {
    let wifi = NetworkInterfaces.IPv4Interface(name: "en0", address: NetworkInterfaces.parse("192.168.1.20")!,
                                               netmask: NetworkInterfaces.parse("255.255.255.0")!)
    let vpn = NetworkInterfaces.IPv4Interface(name: "utun3", address: NetworkInterfaces.parse("10.8.0.2")!,
                                              netmask: NetworkInterfaces.parse("255.255.0.0")!)
    #expect(NetworkInterfaces.localAddress(toward: "10.8.4.4", in: [wifi, vpn]) == "10.8.0.2")
    #expect(NetworkInterfaces.localAddress(toward: "192.168.1.40", in: [vpn, wifi]) == "192.168.1.20")
    #expect(NetworkInterfaces.localAddress(toward: "172.16.0.9", in: [vpn, wifi]) == "192.168.1.20")
}

@Test func byteRangesResolveAgainstSize() {
    #expect(ByteRangeRequest.resolve(nil, size: 1000) == .full)
    #expect(ByteRangeRequest.resolve("bytes=100-199", size: 1000) == .partial(100...199))
    #expect(ByteRangeRequest.resolve("bytes=900-", size: 1000) == .partial(900...999))
    #expect(ByteRangeRequest.resolve("bytes=-100", size: 1000) == .partial(900...999))
    #expect(ByteRangeRequest.resolve("bytes=500-5000", size: 1000) == .partial(500...999))
    #expect(ByteRangeRequest.resolve("bytes=1000-", size: 1000) == .unsatisfiable)
    #expect(ByteRangeRequest.resolve("bytes=0-1,5-6", size: 1000) == .full)
}

@Test func httpRequestHeadParsesAndReportsConsumedBytes() throws {
    let raw = Data("GET /t/abc.flac?x=1 HTTP/1.1\r\nHost: a\r\nRange: bytes=0-\r\nConnection: close\r\n\r\nNEXT".utf8)
    let (head, consumed) = try #require(try HTTPRequestHead.parse(raw))
    #expect(head.method == "GET")
    #expect(head.path == "/t/abc.flac")
    #expect(head.headers["range"] == "bytes=0-")
    #expect(!head.wantsKeepAlive)
    #expect(raw.count - consumed == 4)
    #expect(try HTTPRequestHead.parse(Data("GET / HTTP/1.1\r\nHost".utf8)) == nil)
}

@Test func scpdActionNamesIgnoreArgumentNames() {
    let xml = """
    <scpd><actionList>
      <action><name>Play</name><argumentList><argument><name>Speed</name></argument></argumentList></action>
      <action><name>SetAVTransportURI</name></action>
    </actionList></scpd>
    """
    #expect(UPnPRendererDescription.actionNames(inSCPD: Data(xml.utf8)) == ["Play", "SetAVTransportURI"])
}

@Test func descriptionResolvesAVTransportSCPD() throws {
    let xml = descriptionXML.replacingOccurrences(
        of: "<controlURL>upnp/control/rendertransport1</controlURL>",
        with: "<controlURL>upnp/control/rendertransport1</controlURL><SCPDURL>/upnp/rendertransportSCPD.xml</SCPDURL>")
    let desc = try #require(UPnPRendererDescription.parse(Data(xml.utf8), location: URL(string: "http://192.168.1.40:49152/description.xml")!))
    #expect(desc.avTransportSCPDURL?.absoluteString == "http://192.168.1.40:49152/upnp/rendertransportSCPD.xml")
}
