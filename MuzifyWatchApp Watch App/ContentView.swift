import SwiftUI
import WatchKit

struct ContentView: View {
  @EnvironmentObject
  private var watchSessionManager: WatchSessionManager
  @EnvironmentObject
  private var watchPlaybackManager: WatchPlaybackManager
  @State
  private var isShowingDiagnostics = false
  @State
  private var isShowingSystemNowPlaying = false

  var body: some View {
    NavigationStack {
      List {
        if watchSessionManager.syncedCollections.isEmpty {
          Section("Library") {
            VStack(alignment: .leading, spacing: 6) {
              Text("No synced music yet")
                .font(.headline)
              Text("Sync songs or a playlist from your iPhone to start listening on watch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
        } else {
          ForEach(watchSessionManager.syncedCollections) { collection in
            NavigationLink {
              CollectionDetailView(collection: collection)
                .environmentObject(watchSessionManager)
                .environmentObject(watchPlaybackManager)
            } label: {
              collectionRow(collection)
            }
          }
        }
      }
      .navigationTitle("Muzify")
      .toolbar {
        if !watchPlaybackManager.currentSongTitle.isEmpty {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              isShowingSystemNowPlaying = true
            } label: {
              Image(systemName: "play.square")
            }
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            isShowingDiagnostics = true
          } label: {
            Image(systemName: "gearshape")
          }
        }
      }
      .sheet(isPresented: $isShowingDiagnostics) {
        diagnosticsView
      }
      .sheet(isPresented: $isShowingSystemNowPlaying) {
        SystemNowPlayingView()
      }
    }
    .listStyle(.carousel)
  }

  @ViewBuilder
  private func keyValueRow(label: String, value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
    }
  }

  private func collectionRow(_ collection: WatchSyncCollection) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(collection.title)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Image(systemName: collection.kind == .misc ? "music.note.list" : "music.note")
          .foregroundStyle(.tint)
      }
      HStack {
        Text("\(collection.songs.count) song\(collection.songs.count == 1 ? "" : "s")")
        Spacer()
        Text("\(readySongCount(in: collection)) ready")
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }

  private func statusIconName(_ transferState: WatchSyncTransferState) -> String {
    switch transferState {
    case .pending:
      "arrow.triangle.2.circlepath.circle"
    case .transferred:
      "checkmark.circle.fill"
    case .failed:
      "exclamationmark.triangle.fill"
    }
  }

  private func statusColor(_ transferState: WatchSyncTransferState) -> Color {
    switch transferState {
    case .pending:
      .yellow
    case .transferred:
      .green
    case .failed:
      .orange
    }
  }

  private var diagnosticsView: some View {
    NavigationStack {
      List {
        Section("Connection") {
          keyValueRow(label: "State", value: watchSessionManager.activationStateDescription)
          keyValueRow(label: "Reachable", value: watchSessionManager.isReachable.description)
          keyValueRow(
            label: "Companion",
            value: watchSessionManager.isCompanionAppInstalled.description
          )
        }

        Section("Last Update") {
          Text(watchSessionManager.lastMessage)
          Text(watchSessionManager.lastUpdated)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section("Playback") {
          if watchPlaybackManager.currentSongTitle.isEmpty {
            Text("Nothing playing")
              .foregroundStyle(.secondary)
          } else {
            Text(watchPlaybackManager.currentSongTitle)
            Text(watchPlaybackManager.statusMessage)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        Section {
          Button("Ping Phone") {
            watchSessionManager.requestPhonePing()
          }
        }
      }
      .navigationTitle("Diagnostics")
    }
  }

  private func readySongCount(in collection: WatchSyncCollection) -> Int {
    collection.songs.filter { $0.transferState == .transferred }.count
  }

  fileprivate static func formattedDuration(_ duration: Int) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: TimeInterval(duration)) ?? "-"
  }
}

private struct SystemNowPlayingView: View {
  var body: some View {
    NowPlayingView()
  }
}

#Preview {
  ContentView()
    .environmentObject(WatchSessionManager())
    .environmentObject(WatchPlaybackManager())
}

private struct CollectionDetailView: View {
  let collection: WatchSyncCollection

  @EnvironmentObject
  private var watchSessionManager: WatchSessionManager
  @EnvironmentObject
  private var watchPlaybackManager: WatchPlaybackManager
  @State
  private var isShowingSystemNowPlaying = false

  var body: some View {
    List {
      if !readySongs.isEmpty {
        Section {
          Button("Play All") {
            playCollection(startAt: nil)
          }
        }
      }

      Section("Songs") {
        ForEach(collection.songs) { song in
          Button {
            if song.transferState == .transferred {
              playCollection(startAt: song.id)
            }
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(song.title)
                    .font(.headline)
                    .lineLimit(1)
                  Text(song.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if watchPlaybackManager.currentSongID == song.id {
                  Image(
                    systemName: watchPlaybackManager.isPlaying ? "pause.circle.fill" : "play.circle.fill"
                  )
                  .foregroundStyle(.tint)
                } else {
                  Image(systemName: statusIconName(song.transferState))
                    .foregroundStyle(statusColor(song.transferState))
                }
              }
              HStack {
                if !song.album.isEmpty {
                  Text(song.album)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(ContentView.formattedDuration(song.duration))
              }
              .font(.footnote)
              .foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          .disabled(song.transferState != .transferred)
        }
      }
    }
    .navigationTitle(collection.title)
    .sheet(isPresented: $isShowingSystemNowPlaying) {
      SystemNowPlayingView()
    }
  }

  private var readySongs: [WatchSyncSong] {
    collection.songs.filter { $0.transferState == .transferred }
  }

  private func playCollection(startAt songID: String?) {
    watchPlaybackManager.playCollection(
      title: collection.title,
      songs: collection.songs,
      startAt: songID,
      fileURLProvider: { watchSessionManager.localFileURL(for: $0) }
    )
    isShowingSystemNowPlaying = true
  }

  private func statusIconName(_ transferState: WatchSyncTransferState) -> String {
    switch transferState {
    case .pending:
      "arrow.triangle.2.circlepath.circle"
    case .transferred:
      "checkmark.circle.fill"
    case .failed:
      "exclamationmark.triangle.fill"
    }
  }

  private func statusColor(_ transferState: WatchSyncTransferState) -> Color {
    switch transferState {
    case .pending:
      .yellow
    case .transferred:
      .green
    case .failed:
      .orange
    }
  }
}
