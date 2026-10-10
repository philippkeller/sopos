import CryptoKit
import Foundation
import Security

/// Login for a Navidrome (or any Subsonic-compatible) server, kept in the Keychain.
struct NavidromeAccount: Codable, Equatable {
    var server: String
    var username: String
    var password: String

    private static let keychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ch.philippkeller.sopos.navidrome",
    ]

    static func load() -> NavidromeAccount? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(NavidromeAccount.self, from: data)
    }

    func save() {
        Self.delete()
        var query = Self.keychainQuery
        query[kSecValueData as String] = try? JSONEncoder().encode(self)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(keychainQuery as CFDictionary)
    }
}

struct Song: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Int?
    let coverArt: String?
    let suffix: String?
    let contentType: String?
    let samplingRate: Int?
}

struct Album: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String?
    let coverArt: String?
    let year: Int?
}

struct Playlist: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let songCount: Int?
    let coverArt: String?
}

struct SearchResults {
    var albums: [Album] = []
    var songs: [Song] = []
}

/// Subsonic API client. The speaker streams straight from the server, so `streamURL` must work without the app.
struct NavidromeClient {
    let account: NavidromeAccount

    private var baseURL: URL? {
        var server = account.server.trimmingCharacters(in: .whitespaces)
        if !server.contains("://") { server = "https://" + server }
        while server.hasSuffix("/") { server.removeLast() }
        return URL(string: server)
    }

    /// Token auth: the password itself never leaves the phone, only md5(password + salt).
    private func authItems() -> [URLQueryItem] {
        let salt = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let token = Insecure.MD5.hash(data: Data((account.password + salt).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return [
            URLQueryItem(name: "u", value: account.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "Sopos"),
        ]
    }

    private func url(_ endpoint: String, _ items: [URLQueryItem] = []) -> URL? {
        guard let baseURL,
              var components = URLComponents(url: baseURL.appendingPathComponent("rest/\(endpoint)"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = authItems() + items
        // "+" is legal in queries but many servers read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    private func get(_ endpoint: String, _ items: [URLQueryItem] = []) async throws -> Body {
        guard let url = url(endpoint, items + [URLQueryItem(name: "f", value: "json")]) else {
            throw SonosError(message: "Invalid server address “\(account.server)”.")
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
        guard let body = try? JSONDecoder().decode(Envelope.self, from: data).response else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SonosError(message: "Unexpected answer from \(account.server) (HTTP \(status)).")
        }
        if let error = body.error { throw SonosError(message: error.message ?? "Error \(error.code ?? 0)") }
        return body
    }

    func ping() async throws {
        _ = try await get("ping")
    }

    func playlists() async throws -> [Playlist] {
        try await get("getPlaylists").playlists?.playlist ?? []
    }

    func songs(inPlaylist id: String) async throws -> [Song] {
        try await get("getPlaylist", [URLQueryItem(name: "id", value: id)]).playlist?.entry ?? []
    }

    /// `type`: newest, recent, frequent, alphabeticalByName, random …
    func albums(_ type: String, count: Int = 50) async throws -> [Album] {
        try await get("getAlbumList2", [URLQueryItem(name: "type", value: type),
                                        URLQueryItem(name: "size", value: String(count))]).albumList2?.album ?? []
    }

    func songs(inAlbum id: String) async throws -> [Song] {
        try await get("getAlbum", [URLQueryItem(name: "id", value: id)]).album?.song ?? []
    }

    func randomSongs(count: Int = 100) async throws -> [Song] {
        try await get("getRandomSongs", [URLQueryItem(name: "size", value: String(count))]).randomSongs?.song ?? []
    }

    func search(_ query: String) async throws -> SearchResults {
        let result = try await get("search3", [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: "0"),
            URLQueryItem(name: "albumCount", value: "20"),
            URLQueryItem(name: "songCount", value: "50"),
        ]).searchResult3
        return SearchResults(albums: result?.album ?? [], songs: result?.song ?? [])
    }

    /// Sonos plays MP3, AAC and FLAC up to 48 kHz natively; everything else is transcoded to MP3 by the server.
    func streamURL(_ song: Song) -> (url: URL?, mimeType: String) {
        let suffix = song.suffix?.lowercased() ?? ""
        let native: [String: String] = ["mp3": "audio/mpeg", "flac": "audio/flac", "m4a": "audio/mp4",
                                        "aac": "audio/aac"]
        if let mime = native[suffix], suffix != "flac" || (song.samplingRate ?? 0) <= 48000 {
            return (url("stream", [URLQueryItem(name: "id", value: song.id),
                                   URLQueryItem(name: "format", value: "raw")]), mime)
        }
        return (url("stream", [URLQueryItem(name: "id", value: song.id),
                               URLQueryItem(name: "format", value: "mp3"),
                               URLQueryItem(name: "maxBitRate", value: "320")]), "audio/mpeg")
    }

    func coverURL(_ id: String?, size: Int = 300) -> URL? {
        guard let id else { return nil }
        return url("getCoverArt", [URLQueryItem(name: "id", value: id), URLQueryItem(name: "size", value: String(size))])
    }

    // MARK: JSON

    private struct Envelope: Decodable {
        let response: Body
        enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
    }

    struct Body: Decodable {
        struct APIError: Decodable { let code: Int?; let message: String? }
        struct Playlists: Decodable { let playlist: [Playlist]? }
        struct PlaylistDetail: Decodable { let entry: [Song]? }
        struct AlbumList: Decodable { let album: [Album]? }
        struct AlbumDetail: Decodable { let song: [Song]? }
        struct SongList: Decodable { let song: [Song]? }
        struct Search: Decodable { let album: [Album]?; let song: [Song]? }

        let error: APIError?
        let playlists: Playlists?
        let playlist: PlaylistDetail?
        let albumList2: AlbumList?
        let album: AlbumDetail?
        let randomSongs: SongList?
        let searchResult3: Search?
    }
}
