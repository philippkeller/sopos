import SwiftUI

struct ContentView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showLikedSongs = false
    @AppStorage("source") private var source = Source.radio

    enum Source: String { case radio, library }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(player.room?.name ?? "Sopos")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showLikedSongs = true } label: { Image(systemName: "heart.text.square") }
                            .accessibilityLabel("Liked songs")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
                .sheet(isPresented: $showSettings) { SettingsView() }
                .sheet(isPresented: $showLikedSongs) { LikedSongsView() }
        }
        .safeAreaInset(edge: .bottom) {
            if player.room != nil { NowPlayingBar() }
        }
        .task { await player.start() }
        .task(id: scenePhase) {
            if scenePhase == .active { await player.pollWhileActive() }
        }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK") {}
        } message: {
            Text(player.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if player.room != nil {
            Group {
                if player.library != nil && source == .library { LibraryView() } else { FavoritesList() }
            }
            .safeAreaInset(edge: .top) {
                if player.library != nil {
                    Picker("Source", selection: $source) {
                        Text("Radio").tag(Source.radio)
                        Text("Library").tag(Source.library)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .background(.bar)
                }
            }
        } else if case .failed(let message) = player.phase {
            ContentUnavailableView {
                Label("No speaker found", systemImage: "hifispeaker.fill")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await player.start(forceDiscovery: true) } }
                    .buttonStyle(.borderedProminent)
                Button("Enter IP address") { showSettings = true }
            }
        } else {
            ProgressView("Looking for your Sonos…")
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })
    }
}

private struct FavoritesList: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        List(player.favorites) { favorite in
            Button {
                Task { await player.play(favorite) }
            } label: {
                FavoriteRow(favorite: favorite, isCurrent: favorite.matches(uri: player.nowPlaying.uri))
            }
            .contextMenu {
                Button("Copy debug info", systemImage: "ladybug") {
                    UIPasteboard.general.string = "\(favorite.title)\nURI: \(favorite.uri)\nMetadata: \(favorite.metadata)"
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if player.favorites.isEmpty {
                ContentUnavailableView(
                    "No radio stations yet", systemImage: "radio",
                    description: Text("In the Sonos app, add the Sonos Radio stations you like to your "
                                      + "Sonos Favorites, then pull down here to refresh."))
            }
        }
        .refreshable { await player.reloadFavorites() }
    }
}

private struct FavoriteRow: View {
    let favorite: Favorite
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: favorite.artURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "radio").foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 48)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(favorite.title)
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer()

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct NowPlayingBar: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.openURL) private var openURL
    @State private var isLookingUp = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.nowPlaying.station ?? player.nowPlaying.track ?? "Nothing playing")
                        .font(.headline)
                        .lineLimit(1)
                    if player.nowPlaying.station != nil, let track = player.nowPlaying.track {
                        Text(track)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if player.nowPlaying.isQueue {
                    Button {
                        Task { await player.skip(forward: false) }
                    } label: {
                        Image(systemName: "backward.fill").font(.title2)
                    }
                    .accessibilityLabel("Previous song")
                }
                if player.nowPlaying.title != nil {
                    Button {
                        player.toggleLike()
                    } label: {
                        Image(systemName: player.isCurrentSongLiked ? "heart.fill" : "heart")
                            .font(.system(size: 26))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .sensoryFeedback(.success, trigger: player.isCurrentSongLiked) { _, liked in liked }
                    .accessibilityLabel(player.isCurrentSongLiked ? "Remove from liked songs" : "Like song")
                }
                if player.nowPlaying.track != nil {
                    Button {
                        Task { await openWikipedia() }
                    } label: {
                        if isLookingUp {
                            ProgressView().frame(width: 34, height: 34)
                        } else {
                            Image(systemName: "w.circle").font(.system(size: 30))
                        }
                    }
                    .disabled(isLookingUp)
                    .accessibilityLabel("Open on Wikipedia")
                }
                Button {
                    Task { await player.togglePlayback() }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .contentTransition(.symbolEffect(.replace))
                }
                if player.nowPlaying.isQueue {
                    Button {
                        Task { await player.skip(forward: true) }
                    } label: {
                        Image(systemName: "forward.fill").font(.title2)
                    }
                    .accessibilityLabel("Next song")
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                Slider(
                    value: Binding(get: { player.volume }, set: { player.setVolume($0) }),
                    in: 0...100,
                    onEditingChanged: { player.isDraggingVolume = $0 })
                Image(systemName: "speaker.wave.3.fill")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func openWikipedia() async {
        isLookingUp = true
        defer { isLookingUp = false }
        if let url = await player.wikipediaArticle() { openURL(url) }
    }
}

private struct SettingsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var ip = ""
    @State private var account = NavidromeAccount(server: "", username: "", password: "")
    @State private var isLoggingIn = false
    @State private var loginError: String?

    var body: some View {
        NavigationStack {
            Form {
                if !player.rooms.isEmpty {
                    Section("Room") {
                        ForEach(player.rooms) { room in
                            Button {
                                player.select(room)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(room.name).foregroundStyle(.primary)
                                    Spacer()
                                    if room.id == player.room?.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }

                Section {
                    TextField("e.g. 192.168.1.42", text: $ip)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    Button("Connect") {
                        Task {
                            if await player.connect(host: ip.trimmingCharacters(in: .whitespaces)) { dismiss() }
                        }
                    }
                    .disabled(ip.isEmpty)
                } header: {
                    Text("Speaker IP address")
                } footer: {
                    Text("Only needed if the automatic search fails. You find the IP in the Sonos app "
                         + "(Settings → System → About My System) or in your router.")
                }

                navidromeSection

                Section {
                    Button("Search again") {
                        dismiss()
                        Task { await player.start(forceDiscovery: true) }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var navidromeSection: some View {
        Section {
            if let saved = player.library?.account {
                LabeledContent("Server", value: saved.server)
                LabeledContent("User", value: saved.username)
                Button("Log out", role: .destructive) { player.disconnectLibrary() }
            } else {
                TextField("Server, e.g. music.example.com", text: $account.server)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username", text: $account.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $account.password)
                    .textContentType(.password)
                Button {
                    Task { await logIn() }
                } label: {
                    if isLoggingIn { ProgressView() } else { Text("Log in") }
                }
                .disabled(account.server.isEmpty || account.username.isEmpty || isLoggingIn)
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Navidrome")
        } footer: {
            Text("Play your own music from a Navidrome (or other Subsonic) server. The speaker streams "
                 + "straight from the server, so it has to be reachable from the speaker.")
        }
    }

    private func logIn() async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            try await player.connectLibrary(account)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
    }
}

private struct LikedSongsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                ForEach(player.likedSongs) { song in
                    Button {
                        openInSpotify(song)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).foregroundStyle(.primary)
                            Text([song.artist, song.station].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(song.date, format: .dateTime.day().month().year())
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contextMenu {
                        Button("Open in Spotify", systemImage: "music.note") { openInSpotify(song) }
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = [song.artist, song.title].compactMap { $0 }
                                .joined(separator: " – ")
                        }
                    }
                }
                .onDelete { player.removeLikedSongs(at: $0) }
            }
            .overlay {
                if player.likedSongs.isEmpty {
                    ContentUnavailableView("No liked songs yet", systemImage: "heart",
                                           description: Text("Tap the heart next to a playing song to keep it here."))
                }
            }
            .navigationTitle("Liked songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !player.likedSongs.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
        }
    }

    /// Spotify app search if installed, otherwise the Spotify website.
    private func openInSpotify(_ song: LikedSong) {
        let urls = song.spotifyURLs
        guard let app = urls.app else { return }
        openURL(app) { opened in
            if !opened, let web = urls.web { openURL(web) }
        }
    }
}
