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
            guard let title = item.title, !uri.isEmpty else { return nil }
            let metadata = item.metadata?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Favorite(title: title, uri: uri, metadata: metadata, artURL: artURL(item.albumArtURI))
        }
    }

    /// `coordinatorID` is the RINCON_… id of the room, needed for queue-based favorites.
    func play(_ favorite: Favorite, coordinatorID: String) async throws {
        if favorite.uri.hasPrefix("x-rincon-cpcontainer:") {
            // Playlists/shows must go through the queue; radio streams can be set directly.
            try await call(.avTransport, "RemoveAllTracksFromQueue", [Self.instance])
            try await call(.avTransport, "AddURIToQueue", [
                Self.instance,
                ("EnqueuedURI", favorite.uri),
                ("EnqueuedURIMetaData", favorite.metadata),
                ("DesiredFirstTrackNumberEnqueued", "0"),
                ("EnqueueAsNext", "0"),
            ], timeout: Self.startTimeout)
            try await call(.avTransport, "SetAVTransportURI", [
                Self.instance, ("CurrentURI", "x-rincon-queue:\(coordinatorID)#0"), ("CurrentURIMetaData", ""),
            ], timeout: Self.startTimeout)
        } else {
            try await call(.avTransport, "SetAVTransportURI", [
                Self.instance, ("CurrentURI", favorite.uri), ("CurrentURIMetaData", favorite.metadata),
            ], timeout: Self.startTimeout)
        }
        try await play()
    }

    func nowPlaying() async throws -> NowPlaying {
        async let media = call(.avTransport, "GetMediaInfo", [Self.instance])
        async let position = call(.avTransport, "GetPositionInfo", [Self.instance])
        let (mediaInfo, positionInfo) = try await (media, position)

        let station = DIDLParser.parse(mediaInfo["CurrentURIMetaData"] ?? "").first?.title
        var track: String?
        if let item = DIDLParser.parse(positionInfo["TrackMetaData"] ?? "").first {
            if let stream = item.streamContent, !stream.isEmpty {
                track = stream
            } else {
                track = [item.creator, item.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – ")
            }
        }
        if track == station || track?.isEmpty == true || track?.hasPrefix("x-") == true {
            track = nil
        }
        return NowPlaying(station: station, track: track, uri: mediaInfo["CurrentURI"])
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
