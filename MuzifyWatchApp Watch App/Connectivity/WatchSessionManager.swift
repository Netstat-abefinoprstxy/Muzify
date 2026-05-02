import Combine
import Foundation
import OSLog
import WatchConnectivity

private let watchSyncedSongsDefaultsKey = "WatchConnectivity.syncedSongs"
private let watchSongsDirectoryName = "WatchSongs"

private func watchSongsDirectoryURL() -> URL? {
  let fileManager = FileManager.default
  guard let directoryURL = fileManager.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
  ).first else { return nil }

  let watchSongsDirectoryURL = directoryURL.appendingPathComponent(
    watchSongsDirectoryName,
    isDirectory: true
  )
  if !fileManager.fileExists(atPath: watchSongsDirectoryURL.path) {
    try? fileManager.createDirectory(
      at: watchSongsDirectoryURL,
      withIntermediateDirectories: true
    )
  }
  return watchSongsDirectoryURL
}

@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
  @Published
  var activationStateDescription = "Not activated"
  @Published
  var isReachable = false
  @Published
  var isCompanionAppInstalled = false
  @Published
  var lastMessage = "Waiting for phone"
  @Published
  var lastUpdated = "-"
  @Published
  var syncedSongs = [WatchSyncSong]()

  private let log = OSLog(subsystem: "Muzify", category: "WatchConnectivity")
  private let session: WCSession?

  override init() {
    syncedSongs = Self.loadPersistedSongs()
    if WCSession.isSupported() {
      session = WCSession.default
    } else {
      session = nil
    }
    super.init()
    session?.delegate = self
  }

  func activate() {
    guard let session else {
      activationStateDescription = "WatchConnectivity unavailable"
      return
    }

    activationStateDescription = "Activating"
    lastMessage = "Connecting to phone"
    session.activate()
  }

  func requestPhonePing() {
    guard let session else {
      lastMessage = "WatchConnectivity unavailable"
      return
    }
    guard session.activationState == .activated else {
      lastMessage = "Session not activated"
      return
    }
    guard session.isReachable else {
      lastMessage = "Phone not reachable"
      return
    }

    let payload: [String: Any] = [
      WatchTransferPayload.typeKey: WatchTransferPayloadType.ping.rawValue,
      WatchTransferPayload.messageKey: "Ping from watch",
      WatchTransferPayload.timestampKey: ISO8601DateFormatter().string(from: Date()),
      WatchTransferPayload.sourceKey: "watch",
    ]

    session.sendMessage(payload) { reply in
      Task { @MainActor in
        self.applyPayload(reply)
      }
    } errorHandler: { error in
      Task { @MainActor in
        self.lastMessage = error.localizedDescription
      }
    }
  }

  private func refreshConnectionState(using session: WCSession) {
    isReachable = session.isReachable
    isCompanionAppInstalled = session.isCompanionAppInstalled
  }

  private func applyPayload(_ payload: [String: Any]) {
    if let message = payload[WatchTransferPayload.messageKey] as? String {
      lastMessage = message
    } else if let appName = payload[WatchTransferPayload.appNameKey] as? String {
      lastMessage = "Connected to \(appName)"
    }
    if let timestamp = payload[WatchTransferPayload.timestampKey] as? String {
      lastUpdated = timestamp
    }
    if let reachable = payload[WatchTransferPayload.isReachableKey] as? Bool {
      isReachable = reachable
    }
    if let songDictionaries = payload[WatchTransferPayload.songsKey] as? [[String: Any]] {
      let incomingSongs = songDictionaries.compactMap(WatchSyncSong.init)
      syncedSongs = mergeSyncedSongs(incomingSongs)
      persistSyncedSongs()
    }
  }

  private func mergeSyncedSongs(_ incomingSongs: [WatchSyncSong]) -> [WatchSyncSong] {
    let existingSongsByID = Dictionary(uniqueKeysWithValues: syncedSongs.map { ($0.id, $0) })
    return incomingSongs.map { song in
      guard let existingSong = existingSongsByID[song.id] else { return song }
      return song.withTransferState(
        existingSong.transferState,
        localFileName: existingSong.localFileName
      )
    }
  }

  private func markSongAsTransferred(
    songID: String,
    localFileName: String,
    message: String,
    timestamp: String
  ) {
    syncedSongs = syncedSongs.map { song in
      guard song.id == songID else { return song }
      return song.withTransferState(.transferred, localFileName: localFileName)
    }
    lastMessage = message
    lastUpdated = timestamp
    persistSyncedSongs()
  }

  private func markSongAsFailed(
    songID: String,
    message: String,
    timestamp: String
  ) {
    syncedSongs = syncedSongs.map { song in
      guard song.id == songID else { return song }
      return song.withTransferState(.failed)
    }
    lastMessage = message
    lastUpdated = timestamp
    persistSyncedSongs()
  }

  private func persistSyncedSongs() {
    let songDictionaries = syncedSongs.map(\.dictionary)
    UserDefaults.standard.set(songDictionaries, forKey: watchSyncedSongsDefaultsKey)
  }

  func localFileURL(for song: WatchSyncSong) -> URL? {
    guard song.transferState == .transferred,
          let localFileName = song.localFileName,
          let directoryURL = watchSongsDirectoryURL()
    else { return nil }

    let fileURL = directoryURL.appendingPathComponent(localFileName, isDirectory: false)
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return fileURL
  }

  nonisolated private static func loadPersistedSongs() -> [WatchSyncSong] {
    guard let songDictionaries = UserDefaults.standard.array(
      forKey: watchSyncedSongsDefaultsKey
    ) as? [[String: Any]]
    else { return [] }

    return songDictionaries.compactMap(WatchSyncSong.init)
  }
}

extension WatchSessionManager: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    Task { @MainActor in
      if let error {
        self.activationStateDescription = "Activation failed"
        self.lastMessage = error.localizedDescription
      } else {
        self.activationStateDescription = activationState.description
        self.refreshConnectionState(using: session)
        self.lastMessage = "Watch session ready"
      }
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in
      os_log(
        "Watch reachability changed: %s",
        log: self.log,
        type: .info,
        session.isReachable.description
      )
      self.refreshConnectionState(using: session)
    }
  }

  nonisolated func session(
    _ session: WCSession,
    didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    Task { @MainActor in
      self.applyPayload(applicationContext)
      self.refreshConnectionState(using: session)
    }
  }

  nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
    let metadata = file.metadata ?? [:]
    let songID = metadata[WatchTransferPayload.songIDKey] as? String ?? ""
    let songTitle = metadata[WatchTransferPayload.songTitleKey] as? String ?? "Song"
    let timestamp = metadata[WatchTransferPayload.songSyncedAtKey] as? String ??
      ISO8601DateFormatter().string(from: Date())

    guard !songID.isEmpty,
          let directoryURL = watchSongsDirectoryURL()
    else {
      Task { @MainActor in
        self.lastMessage = "Could not prepare watch storage"
        self.lastUpdated = timestamp
      }
      return
    }

    let pathExtension = file.fileURL.pathExtension
    let destinationURL = directoryURL
      .appendingPathComponent(songID, isDirectory: false)
      .appendingPathExtension(pathExtension.isEmpty ? "audio" : pathExtension)

    do {
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
      }
      try FileManager.default.moveItem(at: file.fileURL, to: destinationURL)

      Task { @MainActor in
        self.markSongAsTransferred(
          songID: songID,
          localFileName: destinationURL.lastPathComponent,
          message: "Transferred \(songTitle)",
          timestamp: timestamp
        )
      }
    } catch {
      let errorDescription = error.localizedDescription
      Task { @MainActor in
        self.markSongAsFailed(
          songID: songID,
          message: "Transfer failed: \(errorDescription)",
          timestamp: timestamp
        )
      }
    }
  }
}

private extension WCSessionActivationState {
  var description: String {
    switch self {
    case .notActivated:
      "Not activated"
    case .inactive:
      "Inactive"
    case .activated:
      "Activated"
    @unknown default:
      "Unknown"
    }
  }
}
