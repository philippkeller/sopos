import Foundation

struct Room: Identifiable, Hashable, Codable {
    /// RINCON_… id of the group coordinator.
    let id: String
    let name: String
    /// IP of the coordinator; all commands for the room go here.
    let host: String
}

struct Favorite: Identifiable, Hashable, Codable {
    var id: String { uri + title }
    let title: String
    let uri: String
    /// DIDL-Lite metadata Sonos needs to play the item (contains the service account).
    let metadata: String
    let artURL: URL?

    /// TuneIn & co. may report the playing URI with different query flags than the stored favorite.
    func matches(uri other: String?) -> Bool {
        guard let other else { return false }
        func base(_ uri: String) -> Substring { uri.split(separator: "?", maxSplits: 1).first ?? Substring(uri) }
        return other == uri || base(other) == base(uri)
    }
}

struct NowPlaying: Equatable {
    var station: String?
    var artist: String?
    var title: String?
    var uri: String?

    /// Library music plays from the speaker's queue, so next/previous make sense.
    var isQueue: Bool { uri?.hasPrefix("x-rincon-queue:") ?? false }

    /// "Artist – Title" for display.
    var track: String? {
        let parts = [artist, title].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " – ")
    }
}

/// A song hearted from the playing bar, to look up again later.
struct LikedSong: Identifiable, Hashable, Codable {
    var id = UUID()
    let artist: String?
    let title: String
    /// Radio station it was heard on (nil for own music).
    let station: String?
    let date: Date

    func matches(_ now: NowPlaying) -> Bool {
        title.caseInsensitiveCompare(now.title ?? "") == .orderedSame
            && (artist ?? "").caseInsensitiveCompare(now.artist ?? "") == .orderedSame
    }

    /// Opens the Spotify app's search; the web link is the fallback when the app isn't installed.
    var spotifyURLs: (app: URL?, web: URL?) {
        let query = [artist, title].compactMap { $0 }.joined(separator: " ")
        // ASCII letters and digits only: accented letters must be percent-encoded too.
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: plain) ?? ""
        return (URL(string: "spotify:search:\(encoded)"), URL(string: "https://open.spotify.com/search/\(encoded)"))
    }
}

/// Tiny UserDefaults wrapper so the app starts instantly with the last known state.
enum Store {
    static let room = "room"
    static let favorites = "favorites"
    static let likedSongs = "likedSongs"

    static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
