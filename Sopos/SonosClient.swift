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

    func next() async throws {
        try await call(.avTransport, "Next", [Self.instance])
    }

    func previous() async throws {
        try await call(.avTransport, "Previous", [Self.instance])
    }

    /// Replaces the speaker's queue with `tracks` and plays it from `index`.
    /// `speakerID` is the RINCON_… id of the coordinator that owns the queue.
    func playQueue(_ tracks: [QueueTrack], from index: Int, speakerID: String) async throws {
        try await call(.avTransport, "RemoveAllTracksFromQueue", [Self.instance])
        // Sonos accepts at most 16 tracks per call; URIs and metadata are space-separated (like SoCo does it).
        for start in stride(from: 0, to: tracks.count, by: 16) {
            let chunk = tracks[start..<min(start + 16, tracks.count)]
            try await call(.avTransport, "AddMultipleURIsToQueue", [
                Self.instance, ("UpdateID", "0"), ("NumberOfURIs", String(chunk.count)),
                ("EnqueuedURIs", chunk.map(\.uri).joined(separator: " ")),
                ("EnqueuedURIsMetaData", chunk.map(\.metadata).joined(separator: " ")),
                ("ContainerURI", ""), ("ContainerMetaData", ""),
                ("DesiredFirstTrackNumberEnqueued", "0"), ("EnqueueAsNext", "0"),
            ], timeout: 10)
        }
        try await call(.avTransport, "SetAVTransportURI", [
            Self.instance, ("CurrentURI", "x-rincon-queue:\(speakerID)#0"), ("CurrentURIMetaData", ""),
        ])
        if index > 0 {
            try await call(.avTransport, "Seek", [Self.instance, ("Unit", "TRACK_NR"), ("Target", String(index + 1))])
        }
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
            // Radio streams echo their URL as title; plain HTTP tracks (Navidrome) carry real metadata.
            if !trackURI.hasPrefix("http"),
               trackURI.contains(value) || (trackURI.removingPercentEncoding ?? "").contains(value) { return nil }
            return value
        }

        var now = NowPlaying(uri: mediaInfo["CurrentURI"])
        now.station = usable(DIDLParser.parse(mediaInfo["CurrentURIMetaData"] ?? "").first?.title)
        if let item = DIDLParser.parse(positionInfo["TrackMetaData"] ?? "").first {
            if let stream = usable(item.streamContent) {
                (now.artist, now.title) = Self.parseStreamContent(stream)
            } else {
                (now.artist, now.title) = (usable(item.creator), usable(item.title))
            }
        }
        if now.title == now.station { now.title = nil }
        return now
    }

    /// Radio services send either "Artist - Title" or tagged "TYPE=SNG|TITLE x|ARTIST y|ALBUM z".
    private static func parseStreamContent(_ content: String) -> (artist: String?, title: String?) {
        guard content.contains("TYPE=SNG|") else {
            guard let dash = content.range(of: " - ") else { return (nil, content) }
            let artist = content[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let title = content[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            return (artist.isEmpty ? nil : artist, title.isEmpty ? nil : title)
        }
        var tags: [String: String] = [:]
        for part in content.split(separator: "|") {
            let pair = part.split(separator: " ", maxSplits: 1)
            if pair.count == 2 { tags[String(pair[0])] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        return (tags["ARTIST"].flatMap { $0.isEmpty ? nil : $0 }, tags["TITLE"].flatMap { $0.isEmpty ? nil : $0 })
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

/// A plain HTTP(S) track plus the DIDL-Lite metadata Sonos shows while it plays.
struct QueueTrack {
    let uri: String
    let metadata: String

    init(url: URL, mimeType: String, title: String, artist: String?, album: String?, duration: Int?,
         artURL: URL?) {
        uri = url.absoluteString
        let duration = duration.map { String(format: " duration=\"%d:%02d:%02d\"", $0 / 3600, $0 / 60 % 60, $0 % 60) } ?? ""
        let optional = [
            artist.map { "<dc:creator>\(xmlEscape($0))</dc:creator>" },
            album.map { "<upnp:album>\(xmlEscape($0))</upnp:album>" },
            artURL.map { "<upnp:albumArtURI>\(xmlEscape($0.absoluteString))</upnp:albumArtURI>" },
        ].compactMap { $0 }.joined()
        metadata = """
            <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
            xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
            <item id="-1" parentID="-1" restricted="true">\
            <res protocolInfo="http-get:*:\(mimeType):*"\(duration)>\(xmlEscape(uri))</res>\
            <dc:title>\(xmlEscape(title))</dc:title>\(optional)\
            <upnp:class>object.item.audioItem.musicTrack</upnp:class></item></DIDL-Lite>
            """
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
