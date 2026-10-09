import SwiftUI

struct ContentView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(player.room?.name ?? "Sopos")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
                .sheet(isPresented: $showSettings) { SettingsView() }
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
            FavoritesList()
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
                FavoriteRow(favorite: favorite, isCurrent: player.nowPlaying.uri == favorite.uri)
            }
        }
        .listStyle(.plain)
        .overlay {
            if player.favorites.isEmpty {
                ContentUnavailableView(
                    "No favorites yet", systemImage: "star",
                    description: Text("In the Sonos app, add the Sonos Radio stations you like to your "
                                      + "Sonos Favorites, then pull down here to refresh."))
            }
        }
        .refreshable { await player.reloadFavorites() }
        .safeAreaInset(edge: .bottom) { NowPlayingBar() }
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
                Button {
                    Task { await player.togglePlayback() }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .contentTransition(.symbolEffect(.replace))
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
}

private struct SettingsView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var ip = ""

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
}
