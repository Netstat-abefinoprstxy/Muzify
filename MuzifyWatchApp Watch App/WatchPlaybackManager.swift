import AVFoundation
import Combine
import Foundation
import OSLog

@MainActor
final class WatchPlaybackManager: NSObject, ObservableObject {
  @Published
  var currentSongID: String?
  @Published
  var currentSongTitle = ""
  @Published
  var isPlaying = false
  @Published
  var statusMessage = "Tap a ready song to play it"

  private let log = OSLog(subsystem: "Muzify", category: "WatchPlayback")
  private var player: AVPlayer?
  private var endObserver: NSObjectProtocol?
  private var playerStatusObservation: NSKeyValueObservation?
  private var playerItemStatusObservation: NSKeyValueObservation?

  deinit {
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
  }

  func togglePlayback(for song: WatchSyncSong, fileURL: URL?) {
    guard let fileURL else {
      statusMessage = "Song file is not available on the watch yet"
      os_log("Playback requested without local file for %s", log: log, type: .error, song.title)
      return
    }

    os_log("Toggle playback for %s (%s)", log: log, type: .info, song.title, fileURL.path)

    if currentSongID == song.id, let player {
      if isPlaying {
        player.pause()
        isPlaying = false
        statusMessage = "Paused \(song.title)"
        os_log("Paused %s", log: log, type: .info, song.title)
      } else {
        do {
          try configureAudioSession()
          player.play()
          isPlaying = true
          statusMessage = "Playing \(song.title)"
          os_log("Resumed %s", log: log, type: .info, song.title)
        } catch {
          statusMessage = error.localizedDescription
          os_log(
            "Failed to resume %s: %s",
            log: log,
            type: .error,
            song.title,
            error.localizedDescription
          )
        }
      }
      return
    }

    play(song: song, fileURL: fileURL)
  }

  private func play(song: WatchSyncSong, fileURL: URL) {
    do {
      try configureAudioSession()
    } catch {
      statusMessage = error.localizedDescription
      os_log(
        "Audio session setup failed for %s: %s",
        log: log,
        type: .error,
        song.title,
        error.localizedDescription
      )
      return
    }

    removeEndObserver()
    removePlayerObservers()

    let playerItem = AVPlayerItem(url: fileURL)
    let player = AVPlayer(playerItem: playerItem)
    self.player = player
    currentSongID = song.id
    currentSongTitle = song.title
    isPlaying = true
    statusMessage = "Playing \(song.title)"
    os_log("Created AVPlayerItem for %s", log: log, type: .info, song.title)

    playerStatusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) {
      [weak self] player, _ in
      Task { @MainActor in
        guard let self else { return }
        let stateDescription: String
        switch player.timeControlStatus {
        case .paused:
          stateDescription = "paused"
        case .waitingToPlayAtSpecifiedRate:
          stateDescription = "waiting"
        case .playing:
          stateDescription = "playing"
        @unknown default:
          stateDescription = "unknown"
        }
        self.statusMessage = "\(song.title): \(stateDescription)"
        os_log(
          "Player timeControlStatus for %s changed to %s",
          log: self.log,
          type: .info,
          song.title,
          stateDescription
        )
      }
    }

    playerItemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) {
      [weak self] playerItem, _ in
      Task { @MainActor in
        guard let self else { return }
        switch playerItem.status {
        case .unknown:
          os_log("Player item status for %s is unknown", log: self.log, type: .info, song.title)
        case .readyToPlay:
          os_log(
            "Player item status for %s is readyToPlay",
            log: self.log,
            type: .info,
            song.title
          )
        case .failed:
          let errorMessage = playerItem.error?.localizedDescription ?? "Unknown player item error"
          self.isPlaying = false
          self.statusMessage = "Playback failed: \(errorMessage)"
          os_log(
            "Player item failed for %s: %s",
            log: self.log,
            type: .error,
            song.title,
            errorMessage
          )
        @unknown default:
          os_log("Player item status for %s is unknown default", log: self.log, type: .info, song.title)
        }
      }
    }

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: playerItem,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.isPlaying = false
        self?.statusMessage = "Finished \(song.title)"
        self?.currentSongID = nil
        self?.currentSongTitle = ""
      }
    }

    os_log("Calling play() for %s", log: log, type: .info, song.title)
    player.play()
  }

  private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default)
    try session.setActive(true)
    os_log("Configured and activated watch audio session", log: log, type: .info)
  }

  private func removeEndObserver() {
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
  }

  private func removePlayerObservers() {
    playerStatusObservation?.invalidate()
    playerStatusObservation = nil
    playerItemStatusObservation?.invalidate()
    playerItemStatusObservation = nil
  }
}
