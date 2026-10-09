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
    var track: String?
    var uri: String?
}

/// Tiny UserDefaults wrapper so the app starts instantly with the last known state.
enum Store {
    static let room = "room"
    static let favorites = "favorites"

    static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
