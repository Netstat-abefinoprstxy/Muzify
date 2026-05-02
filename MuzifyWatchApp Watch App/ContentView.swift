import SwiftUI

struct ContentView: View {
  @EnvironmentObject
  private var watchSessionManager: WatchSessionManager
  @EnvironmentObject
  private var watchPlaybackManager: WatchPlaybackManager

  var body: some View {
    List {
      Section("Muzify Watch") {
        Label("Connectivity Ready", systemImage: "applewatch.radiowaves.left.and.right")
      }

      Section("Session") {
        keyValueRow(label: "State", value: watchSessionManager.activationStateDescription)
        keyValueRow(label: "Reachable", value: watchSessionManager.isReachable.description)
        keyValueRow(
          label: "Companion Installed",
          value: watchSessionManager.isCompanionAppInstalled.description
        )
      }

      Section("Last Update") {
        Text(watchSessionManager.lastMessage)
        Text(watchSessionManager.lastUpdated)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section("Watch Library") {
        if watchSessionManager.syncedSongs.isEmpty {
          Text("No songs synced yet")
            .foregroundStyle(.secondary)
        } else {
          ForEach(watchSessionManager.syncedSongs) { song in
            Button {
              watchPlaybackManager.togglePlayback(
                for: song,
                fileURL: watchSessionManager.localFileURL(for: song)
              )
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                HStack {
                  Text(song.title)
                    .font(.headline)
                    .lineLimit(1)
                  Spacer(minLength: 8)
                  if watchPlaybackManager.currentSongID == song.id {
                    Image(systemName: watchPlaybackManager.isPlaying ? "pause.circle" : "play.circle")
                      .foregroundStyle(.tint)
                  }
                }
                Text(song.artist)
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                HStack {
                  if !song.album.isEmpty {
                    Text(song.album)
                      .lineLimit(1)
                  }
                  Spacer(minLength: 8)
                  Text(formattedDuration(song.duration))
                  Text(transferStateText(song.transferState))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
              }
            }
            .buttonStyle(.plain)
          }
        }
      }

      Section("Playback") {
        if watchPlaybackManager.currentSongTitle.isEmpty {
          Text(watchPlaybackManager.statusMessage)
            .foregroundStyle(.secondary)
        } else {
          Text(watchPlaybackManager.currentSongTitle)
            .lineLimit(1)
          Text(watchPlaybackManager.statusMessage)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Button(watchPlaybackManager.isPlaying ? "Pause" : "Resume") {
            guard let currentSong = watchSessionManager.syncedSongs.first(
              where: { $0.id == watchPlaybackManager.currentSongID }
            ) else { return }
            watchPlaybackManager.togglePlayback(
              for: currentSong,
              fileURL: watchSessionManager.localFileURL(for: currentSong)
            )
          }
        }
      }

      Section {
        Button("Ping Phone") {
          watchSessionManager.requestPhonePing()
        }
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

  private func formattedDuration(_ duration: Int) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: TimeInterval(duration)) ?? "-"
  }

  private func transferStateText(_ transferState: WatchSyncTransferState) -> String {
    switch transferState {
    case .pending:
      "Pending"
    case .transferred:
      "Ready"
    case .failed:
      "Failed"
    }
  }
}

#Preview {
  ContentView()
    .environmentObject(WatchSessionManager())
    .environmentObject(WatchPlaybackManager())
}
