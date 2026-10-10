import Foundation
import Observation

@Observable @MainActor
final class PlayerModel {
    enum Phase {
        case searching
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .searching
    private(set) var rooms: [Room] = []
    private(set) var room: Room?
    private(set) var favorites: [Favorite] = Store.load(Store.favorites) ?? []
    private(set) var isPlaying = false
    private(set) var volume: Double = 0
    private(set) var nowPlaying = NowPlaying()
    var errorMessage: String?
    var isDraggingVolume = false
    private(set) var library: NavidromeClient? = NavidromeAccount.load().map(NavidromeClient.init)

    @ObservationIgnored private var pendingVolume: Int?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?

    private var client: SonosClient? { room.map { SonosClient(host: $0.host) } }

    // MARK: Connecting

    /// Tries the last known speaker first (instant), then falls back to Bonjour discovery.
    func start(forceDiscovery: Bool = false) async {
        phase = .searching
        if !forceDiscovery, let saved: Room = Store.load(Store.room),
           await connect(host: saved.host, silently: true) {
            return
        }
        guard let host = await SpeakerDiscovery.findHost() else {
            report("No Sonos speaker found. Make sure your phone is on the same Wi-Fi and that Sopos may "
                   + "access the local network (iOS Settings → Privacy & Security → Local Network).")
            return
        }
        await connect(host: host)
    }

    @discardableResult
    func connect(host: String, silently: Bool = false) async -> Bool {
        do {
            let found = try await SonosClient(host: host).rooms()
            guard !found.isEmpty else { throw SonosError(message: "The speaker at \(host) reported no rooms.") }
            rooms = found
            let savedID = (Store.load(Store.room) as Room?)?.id
            select(found.first { $0.id == savedID } ?? found[0])
            return true
        } catch {
            if !silently { report("Couldn't reach a speaker at \(host): \(error.localizedDescription)") }
            return false
        }
    }

    func select(_ room: Room) {
        self.room = room
        Store.save(room, Store.room)
        phase = .ready
        Task { await reloadFavorites() }
        Task { await refresh() }
    }

    // MARK: State

    func reloadFavorites() async {
        guard let client else { return }
        do {
            favorites = try await client.favorites()
            Store.save(favorites, Store.favorites)
        } catch {
            errorMessage = "Couldn't load favorites: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        guard let client else { return }
        async let playing = try? client.isPlaying()
        async let currentVolume = try? client.volume()
        async let current = try? client.nowPlaying()

        if let playing = await playing { isPlaying = playing }
        if let currentVolume = await currentVolume, !isDraggingVolume, volumeTask == nil {
            volume = Double(currentVolume)
        }
        if var current = await current {
            if current.station == nil {
                current.station = favorites.first { $0.matches(uri: current.uri) }?.title
            }
            nowPlaying = current
        }
    }

    func pollWhileActive() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    // MARK: Controls

    func play(_ favorite: Favorite) async {
        guard let client else { return }
        nowPlaying = NowPlaying(station: favorite.title, uri: favorite.uri)
        isPlaying = true
        do {
            try await client.play(favorite)
        } catch {
            isPlaying = false
            errorMessage = "Couldn't play \(favorite.title): \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Plays library songs through the speaker's queue, starting at `index`.
    func play(_ songs: [Song], from index: Int = 0) async {
        guard let client, let room, let library, songs.indices.contains(index) else { return }
        let song = songs[index]
        let queueURI = "x-rincon-queue:\(room.id)#0"
        nowPlaying = NowPlaying(artist: song.artist, title: song.title, uri: queueURI)
        isPlaying = true
        let tracks = songs.prefix(500).compactMap { song -> QueueTrack? in
            let stream = library.streamURL(song)
            guard let url = stream.url else { return nil }
            return QueueTrack(url: url, mimeType: stream.mimeType, title: song.title, artist: song.artist,
                              album: song.album, duration: song.duration, artURL: library.coverURL(song.coverArt))
        }
        do {
            try await client.playQueue(tracks, from: index, speakerID: room.id)
        } catch {
            isPlaying = false
            errorMessage = "Couldn't play \(song.title): \(error.localizedDescription)"
        }
        await refresh()
    }

    func skip(forward: Bool) async {
        guard let client else { return }
        do {
            if forward { try await client.next() } else { try await client.previous() }
        } catch {
            errorMessage = forward ? "This is the last song." : "Couldn't go back."
        }
        await refresh()
    }

    /// Checks the login before storing it, so a typo shows up right away.
    func connectLibrary(_ account: NavidromeAccount) async throws {
        let candidate = NavidromeClient(account: account)
        try await candidate.ping()
        account.save()
        library = candidate
    }

    func disconnectLibrary() {
        NavidromeAccount.delete()
        library = nil
    }

    func togglePlayback() async {
        guard let client else { return }
        let wasPlaying = isPlaying
        isPlaying.toggle()
        do {
            if wasPlaying { try await client.pause() } else { try await client.play() }
        } catch {
            isPlaying = wasPlaying
            errorMessage = wasPlaying ? "Couldn't pause." : "Couldn't start playback. Pick a station first."
        }
    }

    /// Updates the UI immediately and sends only the latest value, so dragging never queues up requests.
    func setVolume(_ newValue: Double) {
        volume = newValue
        pendingVolume = Int(newValue.rounded())
        guard volumeTask == nil else { return }
        volumeTask = Task {
            while let target = pendingVolume {
                pendingVolume = nil
                try? await client?.setVolume(target)
            }
            volumeTask = nil
        }
    }

    /// Finds the Wikipedia article for the current song (or its artist); reports an error if there is none.
    func wikipediaArticle() async -> URL? {
        let song = nowPlaying
        do {
            if let url = try await Wikipedia.article(artist: song.artist, title: song.title) { return url }
            errorMessage = "No Wikipedia article found for \(song.track ?? "this song")."
        } catch {
            errorMessage = "Wikipedia search failed: \(error.localizedDescription)"
        }
        return nil
    }

    private func report(_ message: String) {
        if room == nil { phase = .failed(message) } else { errorMessage = message }
    }
}
