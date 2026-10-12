import SwiftUI

/// Own music from Navidrome: search, playlists and recently added albums.
struct LibraryView: View {
    @Environment(PlayerModel.self) private var player
    @State private var query = ""
    @State private var playlists: [Playlist] = []
    @State private var albums: [Album] = []
    @State private var results: SearchResults?
    @State private var loadError: String?

    var body: some View {
        List {
            if let results {
                searchResults(results)
            } else {
                overview
            }
        }
        .listStyle(.plain)
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Songs, albums, artists")
        #else
        .searchable(text: $query, prompt: "Songs, albums, artists")
        #endif
        .task { await load() }
        .task(id: query) { await search() }
        .refreshable { await load() }
        .overlay {
            if let loadError, results == nil, playlists.isEmpty, albums.isEmpty {
                ContentUnavailableView("Library not reachable", systemImage: "music.note.house",
                                       description: Text(loadError))
            }
        }
        .navigationDestination(for: Album.self) { album in
            SongList(title: album.name, showsArtist: false) { try await $0.songs(inAlbum: album.id) }
        }
        .navigationDestination(for: Playlist.self) { playlist in
            SongList(title: playlist.name, showsArtist: true) { try await $0.songs(inPlaylist: playlist.id) }
        }
    }

    @ViewBuilder
    private var overview: some View {
        Section {
            Button {
                Task { await shuffleEverything() }
            } label: {
                Label("Shuffle everything", systemImage: "shuffle")
            }
            .rowButton()
        }
        if !playlists.isEmpty {
            Section("Playlists") {
                ForEach(playlists) { playlist in
                    NavigationLink(value: playlist) {
                        CoverRow(title: playlist.name, subtitle: playlist.songCount.map { "\($0) songs" },
                                 cover: player.library?.coverURL(playlist.coverArt, size: 120))
                    }
                }
            }
        }
        if !albums.isEmpty {
            Section("Recently added") {
                ForEach(albums) { album in
                    NavigationLink(value: album) { albumRow(album) }
                }
            }
        }
    }

    @ViewBuilder
    private func searchResults(_ results: SearchResults) -> some View {
        if !results.albums.isEmpty {
            Section("Albums") {
                ForEach(results.albums) { album in
                    NavigationLink(value: album) { albumRow(album) }
                }
            }
        }
        if !results.songs.isEmpty {
            Section("Songs") {
                ForEach(results.songs) { song in
                    Button {
                        Task { await player.play([song]) }
                    } label: {
                        CoverRow(title: song.title, subtitle: song.artist,
                                 cover: player.library?.coverURL(song.coverArt, size: 120))
                    }
                    .rowButton()
                }
            }
        }
        if results.albums.isEmpty && results.songs.isEmpty {
            Text("Nothing found for “\(query)”.").foregroundStyle(.secondary)
        }
    }

    private func albumRow(_ album: Album) -> some View {
        let subtitle = [album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        return CoverRow(title: album.name, subtitle: subtitle.isEmpty ? nil : subtitle,
                        cover: player.library?.coverURL(album.coverArt, size: 120))
    }

    private func load() async {
        guard let library = player.library else { return }
        do {
            async let lists = library.playlists()
            async let newest = library.albums("newest")
            (playlists, albums) = try await (lists, newest)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let library = player.library else {
            results = nil
            return
        }
        // Wait until typing pauses; a new keystroke cancels this task.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            results = try await library.search(text)
        } catch {
            if !Task.isCancelled { player.errorMessage = "Search failed: \(error.localizedDescription)" }
        }
    }

    private func shuffleEverything() async {
        guard let library = player.library else { return }
        do {
            let songs = try await library.randomSongs()
            await player.play(songs)
        } catch {
            player.errorMessage = "Couldn't load songs: \(error.localizedDescription)"
        }
    }
}

/// Songs of an album or playlist; tapping a song plays the whole list from there.
private struct SongList: View {
    @Environment(PlayerModel.self) private var player
    let title: String
    let showsArtist: Bool
    let load: (NavidromeClient) async throws -> [Song]
    @State private var songs: [Song]?
    @State private var loadError: String?

    var body: some View {
        List {
            if let songs, !songs.isEmpty {
                Section {
                    HStack {
                        Button {
                            Task { await player.play(songs) }
                        } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        Button {
                            Task { await player.play(songs.shuffled()) }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        Button {
                            Task { await player.play(songs, from: index) }
                        } label: {
                            songRow(song)
                        }
                        .rowButton()
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if let loadError {
                ContentUnavailableView("Couldn't load songs", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else if songs == nil {
                ProgressView()
            }
        }
        .task {
            guard songs == nil, let library = player.library else { return }
            do {
                songs = try await load(library)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func songRow(_ song: Song) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).foregroundStyle(.primary).lineLimit(1)
                if showsArtist, let artist = song.artist {
                    Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let duration = song.duration {
                Text(String(format: "%d:%02d", duration / 60, duration % 60))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct CoverRow: View {
    let title: String
    let subtitle: String?
    let cover: URL?

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: cover) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 48)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
