import Foundation

struct SonosError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A UPnP service exposed by every Sonos speaker on port 1400.
struct SonosService {
    let path: String
    let urn: String

    static let avTransport = SonosService(
        path: "/MediaRenderer/AVTransport/Control",
        urn: "urn:schemas-upnp-org:service:AVTransport:1")
    static let renderingControl = SonosService(
        path: "/MediaRenderer/RenderingControl/Control",
        urn: "urn:schemas-upnp-org:service:RenderingControl:1")
    static let contentDirectory = SonosService(
        path: "/MediaServer/ContentDirectory/Control",
        urn: "urn:schemas-upnp-org:service:ContentDirectory:1")
    static let zoneGroupTopology = SonosService(
        path: "/ZoneGroupTopology/Control",
        urn: "urn:schemas-upnp-org:service:ZoneGroupTopology:1")
}

/// Talks directly to one speaker over the LAN (no Sonos cloud involved).
struct SonosClient {
    let host: String

    private static let session = URLSession(configuration: .ephemeral)

    @discardableResult
    func call(_ service: SonosService, _ action: String, _ args: [(String, String)] = [],
              timeout: TimeInterval = 4) async throws -> [String: String] {
        let url = URL(string: "http://\(host):1400\(service.path)")!
        let argXML = args.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        let body = """
            <?xml version="1.0" encoding="utf-8"?>\
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
            <s:Body><u:\(action) xmlns:u="\(service.urn)">\(argXML)</u:\(action)></s:Body></s:Envelope>
            """

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await Self.session.data(for: request)
        let fields = LeafXMLParser.parse(data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let code = fields["errorCode"].map { ", UPnP error \($0)" } ?? ""
            throw SonosError(message: "\(action) failed (HTTP \(status)\(code))")
        }
        return fields
    }
}

// MARK: - Playback

extension SonosClient {
    private static let instance = ("InstanceID", "0")
    /// Starting a stream makes the speaker contact the radio service first (TuneIn can take several seconds).
    private static let startTimeout: TimeInterval = 20

    func play() async throws {
        try await call(.avTransport, "Play", [Self.instance, ("Speed", "1")], timeout: Self.startTimeout)
    }

    func pause() async throws {
        do {
            try await call(.avTransport, "Pause", [Self.instance])
        } catch {
            // Some live radio streams can't be paused, only stopped.
            try await call(.avTransport, "Stop", [Self.instance])
        }
    }

    func isPlaying() async throws -> Bool {
        let result = try await call(.avTransport, "GetTransportInfo", [Self.instance])
        let state = result["CurrentTransportState"] ?? ""
        return state == "PLAYING" || state == "TRANSITIONING"
    }

    func volume() async throws -> Int {
        let result = try await call(.renderingControl, "GetVolume", [Self.instance, ("Channel", "Master")])
        return Int(result["CurrentVolume"] ?? "") ?? 0
    }

    func setVolume(_ volume: Int) async throws {
        try await call(.renderingControl, "SetVolume",
                       [Self.instance, ("Channel", "Master"), ("DesiredVolume", String(volume))])
    }

    func favorites() async throws -> [Favorite] {
        let result = try await call(.contentDirectory, "Browse", [
            ("ObjectID", "FV:2"),
            ("BrowseFlag", "BrowseDirectChildren"),
            ("Filter", "*"),
            ("StartingIndex", "0"),
            ("RequestedCount", "200"),
            ("SortCriteria", ""),
        ])
        return DIDLParser.parse(result["Result"] ?? "").compactMap { item in
            let uri = item.uri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let metadata = item.metadata?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let title = item.title, Self.isRadio(uri: uri, metadata: metadata) else { return nil }
            return Favorite(title: title, uri: uri, metadata: metadata, artURL: artURL(item.albumArtURI))
        }
    }

    func play(_ favorite: Favorite) async throws {
        try await call(.avTransport, "SetAVTransportURI", [
            Self.instance, ("CurrentURI", favorite.uri), ("CurrentURIMetaData", favorite.metadata),
        ], timeout: Self.startTimeout)
        try await play()
    }

    /// Mirrors SoCo's `get_current_track_info` heuristics for radio metadata.
    func nowPlaying() async throws -> NowPlaying {
        async let media = call(.avTransport, "GetMediaInfo", [Self.instance])
        async let position = call(.avTransport, "GetPositionInfo", [Self.instance])
        let (mediaInfo, positionInfo) = try await (media, position)

        let trackURI = positionInfo["TrackURI"] ?? ""
        // Drops placeholders: status codes (ZPSTR_CONNECTING), "NOT_IMPLEMENTED" and URL fragments posing as titles.
        func usable(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  !value.hasPrefix("ZPSTR_"), value != "NOT_IMPLEMENTED", !value.hasPrefix("x-") else { return nil }
            if trackURI.contains(value) || (trackURI.removingPercentEncoding ?? "").contains(value) { return nil }
            return value
        }

        let station = usable(DIDLParser.parse(mediaInfo["CurrentURIMetaData"] ?? "").first?.title)
        var track: String?
        if let item = DIDLParser.parse(positionInfo["TrackMetaData"] ?? "").first {
            if let stream = usable(item.streamContent) {
                track = Self.parseStreamContent(stream)
            } else {
                let parts = [usable(item.creator), usable(item.title)].compactMap { $0 }
                track = parts.isEmpty ? nil : parts.joined(separator: " – ")
            }
        }
        if track == station { track = nil }
        return NowPlaying(station: station, track: track, uri: mediaInfo["CurrentURI"])
    }

    /// Radio services send either "Artist - Title" or tagged "TYPE=SNG|TITLE x|ARTIST y|ALBUM z".
    private static func parseStreamContent(_ content: String) -> String? {
        guard content.contains("TYPE=SNG|") else { return content }
        var tags: [String: String] = [:]
        for part in content.split(separator: "|") {
            let pair = part.split(separator: " ", maxSplits: 1)
            if pair.count == 2 { tags[String(pair[0])] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        let parts = [tags["ARTIST"], tags["TITLE"]].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " – ")
    }

    /// Radio stations only: playlists, albums and folders (e.g. a "coding" playlist) are hidden.
    private static func isRadio(uri: String, metadata: String) -> Bool {
        let radioSchemes = ["x-sonosapi-stream:", "x-sonosapi-radio:", "x-sonosapi-hls:", "x-rincon-mp3radio:",
                            "aac:", "hls-radio:"]
        if radioSchemes.contains(where: uri.hasPrefix) { return true }
        let itemClass = DIDLParser.parse(metadata).first?.itemClass ?? ""
        return itemClass.contains("audioBroadcast")
    }

    private func artURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") { return URL(string: "http://\(host):1400\(raw)") }
        return URL(string: raw)
    }
}

// MARK: - Rooms

extension SonosClient {
    /// All rooms (zone groups) in the household, each addressed via its coordinator.
    func rooms() async throws -> [Room] {
        let result = try await call(.zoneGroupTopology, "GetZoneGroupState")
        return ZoneGroupParser.parse(result["ZoneGroupState"] ?? "")
    }
}

func xmlEscape(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
