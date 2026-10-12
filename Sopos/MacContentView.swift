#if os(macOS)
import AppKit
import SwiftUI

/// The Mac window: sections in a sidebar, the playing bar along the bottom, settings under ⌘,.
struct MacContentView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @AppStorage("macPane") private var pane = Pane.radio

    enum Pane: String { case radio, library, liked }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Label("Radio", systemImage: "radio").tag(Pane.radio)
                if player.library != nil {
                    Label("Library", systemImage: "music.note.house").tag(Pane.library)
                }
                Label("Liked songs", systemImage: "heart").tag(Pane.liked)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            NavigationStack {
                detail.navigationTitle(player.room?.name ?? "Sopos")
            }
            // Switching panes starts with a fresh navigation stack.
            .id(pane)
            .safeAreaInset(edge: .bottom) {
                if player.room != nil { NowPlayingBar() }
            }
        }
        .toolbar {
            if player.rooms.count > 1 {
                ToolbarItem {
                    Picker("Room", selection: room) {
                        ForEach(player.rooms) { Text($0.name).tag(Optional($0)) }
                    }
                    .help("Room")
                }
            }
        }
        .frame(minWidth: 680, minHeight: 440)
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
    private var detail: some View {
        if pane == .liked {
            LikedSongsList()
        } else if player.room == nil {
            SpeakerSearchView { openSettings() }
        } else if pane == .library && player.library != nil {
            LibraryView()
        } else {
            FavoritesGrid()
        }
    }

    private var selection: Binding<Pane?> {
        Binding(get: { pane }, set: { if let new = $0 { pane = new } })
    }

    private var room: Binding<Room?> {
        Binding(get: { player.room }, set: { if let new = $0 { player.select(new) } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })
    }
}

/// Radio stations as a grid of covers, which uses a wide window better than a list.
private struct FavoritesGrid: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 20)], spacing: 20) {
                ForEach(player.favorites) { favorite in
                    Button {
                        Task { await player.play(favorite) }
                    } label: {
                        FavoriteTile(favorite: favorite, isCurrent: favorite.matches(uri: player.nowPlaying.uri))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Copy debug info", systemImage: "ladybug") { Clipboard.copy(favorite.debugInfo) }
                    }
                }
            }
            .padding(20)
        }
        .overlay {
            if player.favorites.isEmpty {
                ContentUnavailableView(
                    "No radio stations yet", systemImage: "radio",
                    description: Text("In the Sonos app, add the Sonos Radio stations you like to your "
                                      + "Sonos Favorites, then reload here (⌘R)."))
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await player.reloadFavorites() }
                } label: {
                    Label("Reload favorites", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .help("Reload favorites (⌘R)")
            }
        }
    }
}

private struct FavoriteTile: View {
    let favorite: Favorite
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    AsyncImage(url: favorite.artURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "radio").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if isCurrent { RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 3) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(.tint)
                            .padding(6)
                            .background(.regularMaterial, in: Circle())
                            .padding(8)
                    }
                }

            Text(favorite.title)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .lineLimit(2, reservesSpace: true)
        }
        .contentShape(Rectangle())
    }
}

/// Menu bar commands with keyboard shortcuts, like in Music.
@MainActor
struct PlaybackCommands: Commands {
    let player: PlayerModel

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play/Pause") { Task { await player.togglePlayback() } }
                .keyboardShortcut("p")
            Button("Next Song") {
                if player.nowPlaying.isQueue { Task { await player.skip(forward: true) } }
            }
            .keyboardShortcut(.rightArrow)
            Button("Previous Song") {
                if player.nowPlaying.isQueue { Task { await player.skip(forward: false) } }
            }
            .keyboardShortcut(.leftArrow)
            Divider()
            Button("Volume Up") { player.setVolume(min(100, player.volume + 5)) }
                .keyboardShortcut(.upArrow)
            Button("Volume Down") { player.setVolume(max(0, player.volume - 5)) }
                .keyboardShortcut(.downArrow)
            Divider()
            Button("Like Song") { player.toggleLike() }
                .keyboardShortcut("l")
        }
    }
}

/// A remote is a single window: closing it quits the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
