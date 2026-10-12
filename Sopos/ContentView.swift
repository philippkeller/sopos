import SwiftUI

#if os(iOS)
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
        } else {
            SpeakerSearchView { showSettings = true }
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
                Button("Copy debug info", systemImage: "ladybug") { Clipboard.copy(favorite.debugInfo) }
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

private struct LikedSongsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LikedSongsList()
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
}
#endif

/// Shown until a speaker answers: a spinner while searching, help when none was found.
struct SpeakerSearchView: View {
    @Environment(PlayerModel.self) private var player
    let enterIPAddress: () -> Void

    var body: some View {
        if case .failed(let message) = player.phase {
            ContentUnavailableView {
                Label("No speaker found", systemImage: "hifispeaker.fill")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await player.start(forceDiscovery: true) } }
                    .buttonStyle(.borderedProminent)
                Button("Enter IP address", action: enterIPAddress)
            }
        } else {
            ProgressView("Looking for your Sonos…")
        }
    }
}

struct NowPlayingBar: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.openURL) private var openURL
    @State private var isLookingUp = false

    #if os(macOS)
    private static let playSize: CGFloat = 34, wikipediaSize: CGFloat = 20, heartSize: CGFloat = 18
    private static let skipFont = Font.title3
    #else
    private static let playSize: CGFloat = 52, wikipediaSize: CGFloat = 30, heartSize: CGFloat = 26
    private static let skipFont = Font.title2
    #endif

    var body: some View {
        #if os(macOS)
        // A laptop window is wide: everything fits in one row.
        HStack(spacing: 16) {
            titles.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                previousButton
                playButton
                nextButton
            }
            HStack(spacing: 12) {
                wikipediaButton
                likeButton
            }
            volumeSlider.frame(width: 150)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        #else
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                titles
                Spacer()
                previousButton
                wikipediaButton
                likeButton
                playButton
                nextButton
            }
            volumeSlider
        }
        .padding(.horizontal)
        .padding(.vertical, 14)
        .background(.bar)
        #endif
    }

    private var titles: some View {
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
    }

    @ViewBuilder
    private var previousButton: some View {
        if player.nowPlaying.isQueue {
            Button {
                Task { await player.skip(forward: false) }
            } label: {
                Image(systemName: "backward.fill").font(Self.skipFont)
            }
            .accessibilityLabel("Previous song")
        }
    }

    @ViewBuilder
    private var nextButton: some View {
        if player.nowPlaying.isQueue {
            Button {
                Task { await player.skip(forward: true) }
            } label: {
                Image(systemName: "forward.fill").font(Self.skipFont)
            }
            .accessibilityLabel("Next song")
        }
    }

    @ViewBuilder
    private var wikipediaButton: some View {
        if player.nowPlaying.track != nil {
            Button {
                Task { await openWikipedia() }
            } label: {
                if isLookingUp {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: Self.wikipediaSize + 4, height: Self.wikipediaSize + 4)
                } else {
                    Image(systemName: "w.circle").font(.system(size: Self.wikipediaSize))
                }
            }
            .disabled(isLookingUp)
            .accessibilityLabel("Open on Wikipedia")
            .help("Open on Wikipedia")
        }
    }

    @ViewBuilder
    private var likeButton: some View {
        if player.nowPlaying.title != nil {
            Button {
                player.toggleLike()
            } label: {
                Image(systemName: player.isCurrentSongLiked ? "heart.fill" : "heart")
                    .font(.system(size: Self.heartSize))
                    .contentTransition(.symbolEffect(.replace))
            }
            .sensoryFeedback(.success, trigger: player.isCurrentSongLiked) { _, liked in liked }
            .accessibilityLabel(player.isCurrentSongLiked ? "Remove from liked songs" : "Like song")
            .help(player.isCurrentSongLiked ? "Remove from liked songs" : "Like song")
        }
    }

    private var playButton: some View {
        Button {
            Task { await player.togglePlayback() }
        } label: {
            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: Self.playSize))
                .contentTransition(.symbolEffect(.replace))
        }
        #if os(macOS)
        .foregroundStyle(.tint)
        #endif
    }

    private var volumeSlider: some View {
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

    private func openWikipedia() async {
        isLookingUp = true
        defer { isLookingUp = false }
        if let url = await player.wikipediaArticle() { openURL(url) }
    }
}

/// A sheet on iPhone, the Settings window (⌘,) on the Mac.
struct SettingsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var ip = ""
    @State private var account = NavidromeAccount(server: "", username: "", password: "")
    @State private var isLoggingIn = false
    @State private var loginError: String?

    var body: some View {
        #if os(macOS)
        form
            .formStyle(.grouped)
            .frame(width: 480, height: 460)
        #else
        NavigationStack {
            form
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        #endif
    }

    private var form: some View {
        Form {
            #if os(iOS)
            // On the Mac the room picker sits in the window's toolbar.
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
            #endif

            Section {
                TextField("IP address", text: $ip, prompt: Text("e.g. 192.168.1.42"))
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
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
    }

    private var navidromeSection: some View {
        Section {
            if let saved = player.library?.account {
                LabeledContent("Server", value: saved.server)
                LabeledContent("User", value: saved.username)
                Button("Log out", role: .destructive) { player.disconnectLibrary() }
            } else {
                TextField("Server", text: $account.server, prompt: Text("Server, e.g. music.example.com"))
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                TextField("Username", text: $account.username)
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField("Password", text: $account.password)
                    .textContentType(.password)
                Button {
                    Task { await logIn() }
                } label: {
                    if isLoggingIn { ProgressView().controlSize(.small) } else { Text("Log in") }
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

/// Hearted songs, newest first; tapping one looks it up on Spotify.
struct LikedSongsList: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.openURL) private var openURL

    var body: some View {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .rowButton()
                .contextMenu {
                    Button("Open in Spotify", systemImage: "music.note") { openInSpotify(song) }
                    Button("Copy", systemImage: "doc.on.doc") {
                        Clipboard.copy([song.artist, song.title].compactMap { $0 }.joined(separator: " – "))
                    }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        if let index = player.likedSongs.firstIndex(of: song) { player.removeLikedSongs(at: [index]) }
                    }
                }
            }
            .onDelete { player.removeLikedSongs(at: $0) }
        }
        .overlay {
            if player.likedSongs.isEmpty {
                ContentUnavailableView("No liked songs yet", systemImage: "heart",
                                       description: Text("Heart a playing song to keep it here."))
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
