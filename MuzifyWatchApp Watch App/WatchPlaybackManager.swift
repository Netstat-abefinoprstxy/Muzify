import AVFoundation
import Combine
import Foundation
import MediaPlayer
import OSLog

@MainActor
final class WatchPlaybackManager: NSObject, ObservableObject {
  struct QueueEntry {
    let song: WatchSyncSong
    let fileURL: URL
  }

  @Published
  var currentSongID: String?
  @Published
  var currentSongTitle = ""
  @Published
  var isPlaying = false
  @Published
  var statusMessage = "Tap a ready song to play it"
  @Published
  var queueTitle = ""

  private let log = OSLog(subsystem: "Muzify", category: "WatchPlayback")
  private var player: AVPlayer?
  private var endObserver: NSObjectProtocol?
  private var playerStatusObservation: NSKeyValueObservation?
  private var playerItemStatusObservation: NSKeyValueObservation?
  private var currentQueue = [QueueEntry]()
  private var currentQueueIndex = 0

  var canPlayPrevious: Bool {
    currentQueueIndex > 0
  }

  var canPlayNext: Bool {
    currentQueueIndex + 1 < currentQueue.count
  }

  deinit {
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
  }

  override init() {
    super.init()
    configureRemoteCommandCenter()
  }

  func playCollection(
    title: String,
    songs: [WatchSyncSong],
    startAt selectedSongID: String? = nil,
    fileURLProvider: (WatchSyncSong) -> URL?
  ) {
    let queueEntries = songs.compactMap { song -> QueueEntry? in
      guard let fileURL = fileURLProvider(song) else { return nil }
      return QueueEntry(song: song, fileURL: fileURL)
    }

    guard !queueEntries.isEmpty else {
      statusMessage = "No ready songs in this collection yet"
      return
    }

    currentQueue = queueEntries
    queueTitle = title
    if let selectedSongID,
       let selectedIndex = queueEntries.firstIndex(where: { $0.song.id == selectedSongID }) {
      currentQueueIndex = selectedIndex
    } else {
      currentQueueIndex = 0
    }

    let selectedEntry = currentQueue[currentQueueIndex]
    playCurrentQueueEntry(entry: selectedEntry)
  }

  func toggleCurrentPlayback() {
    guard let currentSongID,
          let currentEntry = currentQueue.first(where: { $0.song.id == currentSongID })
    else {
      statusMessage = "Nothing loaded yet"
      return
    }

    togglePlayback(for: currentEntry.song, fileURL: currentEntry.fileURL)
  }

  func playPrevious() {
    guard canPlayPrevious else { return }
    currentQueueIndex -= 1
    playCurrentQueueEntry(entry: currentQueue[currentQueueIndex])
  }

  func playNext() {
    guard canPlayNext else { return }
    currentQueueIndex += 1
    playCurrentQueueEntry(entry: currentQueue[currentQueueIndex])
  }

  private func togglePlayback(for song: WatchSyncSong, fileURL: URL?) {
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
        updatePlaybackStateInNowPlayingInfo()
        os_log("Paused %s", log: log, type: .info, song.title)
      } else {
        do {
          try configureAudioSession()
          player.play()
          isPlaying = true
          statusMessage = "Playing \(song.title)"
          updatePlaybackStateInNowPlayingInfo()
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

  private func playCurrentQueueEntry(entry: QueueEntry) {
    if let queueIndex = currentQueue.firstIndex(where: { $0.song.id == entry.song.id }) {
      currentQueueIndex = queueIndex
    }
    play(song: entry.song, fileURL: entry.fileURL)
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
    updateNowPlayingInfo(for: song)
    updateRemoteCommandAvailability()
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
        self.statusMessage = stateDescription.capitalized
        self.updatePlaybackStateInNowPlayingInfo()
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
          self.updatePlaybackStateInNowPlayingInfo()
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
        guard let self else { return }
        if self.canPlayNext {
          self.currentQueueIndex += 1
          self.playCurrentQueueEntry(entry: self.currentQueue[self.currentQueueIndex])
        } else {
          self.isPlaying = false
          self.statusMessage = "Finished"
          self.currentSongID = nil
          self.currentSongTitle = ""
          self.queueTitle = ""
          self.clearNowPlayingInfo()
        }
      }
    }

    os_log("Calling play() for %s", log: log, type: .info, song.title)
    player.play()
  }

  private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
    try session.setActive(true)
    os_log("Configured and activated watch audio session", log: log, type: .info)
  }

  private func configureRemoteCommandCenter() {
    let commandCenter = MPRemoteCommandCenter.shared()

    commandCenter.playCommand.isEnabled = true
    commandCenter.playCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        self?.resumeFromRemoteCommand()
      }
      return .success
    }

    commandCenter.pauseCommand.isEnabled = true
    commandCenter.pauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        self?.pauseFromRemoteCommand()
      }
      return .success
    }

    commandCenter.togglePlayPauseCommand.isEnabled = true
    commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        self?.toggleCurrentPlayback()
      }
      return .success
    }

    commandCenter.nextTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        self?.playNext()
      }
      return .success
    }

    commandCenter.previousTrackCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        self?.playPrevious()
      }
      return .success
    }

    updateRemoteCommandAvailability()
  }

  private func updateRemoteCommandAvailability() {
    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.previousTrackCommand.isEnabled = canPlayPrevious
    commandCenter.nextTrackCommand.isEnabled = canPlayNext
  }

  private func updateNowPlayingInfo(for song: WatchSyncSong) {
    var nowPlayingInfo: [String: Any] = [
      MPMediaItemPropertyTitle: song.title,
      MPMediaItemPropertyArtist: song.artist,
      MPMediaItemPropertyAlbumTitle: song.album,
      MPMediaItemPropertyPlaybackDuration: TimeInterval(song.duration),
      MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
      MPNowPlayingInfoPropertyExternalContentIdentifier: song.id,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
    ]

    if let player {
      nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
      nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
    }

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    os_log("Updated MPNowPlayingInfoCenter for %s", log: log, type: .info, song.title)
  }

  private func updatePlaybackStateInNowPlayingInfo() {
    guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
    else { return }

    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
    if let player {
      nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime().seconds
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  private func clearNowPlayingInfo() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    updateRemoteCommandAvailability()
  }

  private func pauseFromRemoteCommand() {
    guard let player, isPlaying else { return }
    player.pause()
    isPlaying = false
    statusMessage = "Paused"
    updatePlaybackStateInNowPlayingInfo()
  }

  private func resumeFromRemoteCommand() {
    guard let player, !isPlaying else { return }
    do {
      try configureAudioSession()
      player.play()
      isPlaying = true
      statusMessage = "Playing"
      updatePlaybackStateInNowPlayingInfo()
    } catch {
      statusMessage = error.localizedDescription
    }
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
