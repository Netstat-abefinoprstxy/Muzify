import Combine
import Foundation
import OSLog
import WatchConnectivity

private let watchSyncedCollectionsDefaultsKey = "WatchConnectivity.syncedCollections"
private let watchLegacySyncedSongsDefaultsKey = "WatchConnectivity.syncedSongs"
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
  var syncedCollections = [WatchSyncCollection]()

  private let log = OSLog(subsystem: "Muzify", category: "WatchConnectivity")
  private let session: WCSession?

  override init() {
    syncedCollections = Self.loadPersistedCollections()
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
    if let collectionDictionaries = payload[WatchTransferPayload.collectionsKey] as? [[String: Any]] {
      let incomingCollections = collectionDictionaries.compactMap(WatchSyncCollection.init)
      applyCollections(incomingCollections)
    } else if let songDictionaries = payload[WatchTransferPayload.songsKey] as? [[String: Any]] {
      let incomingSongs = songDictionaries.compactMap(WatchSyncSong.init)
      let incomingCollections = [
        WatchSyncCollection(
          id: WatchSyncCollection.miscID,
          title: WatchSyncCollection.miscTitle,
          kind: .misc,
          songs: incomingSongs
        ),
      ]
      applyCollections(incomingCollections)
    }
  }

  private func applyCollections(_ incomingCollections: [WatchSyncCollection]) {
    let existingSongsByID = Dictionary(uniqueKeysWithValues: allSyncedSongs.map { ($0.id, $0) })
    let previousReferencedSongIDs = referencedSongIDs(in: syncedCollections)
    let incomingReferencedSongIDs = referencedSongIDs(in: incomingCollections)
    let mergedCollections = incomingCollections.map { collection in
      WatchSyncCollection(
        id: collection.id,
        title: collection.title,
        kind: collection.kind,
        songs: collection.songs.map { song in
          guard let existingSong = existingSongsByID[song.id] else { return song }
          return song.withTransferState(
            existingSong.transferState,
            localFileName: existingSong.localFileName
          )
        }
      )
    }

    cleanupOrphanedFiles(
      removedSongIDs: previousReferencedSongIDs.subtracting(incomingReferencedSongIDs),
      existingSongsByID: existingSongsByID
    )
    syncedCollections = mergedCollections
    persistSyncedCollections()
  }

  private func markSongAsTransferred(
    songID: String,
    localFileName: String,
    message: String,
    timestamp: String
  ) {
    syncedCollections = syncedCollections.map { collection in
      WatchSyncCollection(
        id: collection.id,
        title: collection.title,
        kind: collection.kind,
        songs: collection.songs.map { song in
          guard song.id == songID else { return song }
          return song.withTransferState(.transferred, localFileName: localFileName)
        }
      )
    }
    lastMessage = message
    lastUpdated = timestamp
    persistSyncedCollections()
  }

  private func markSongAsFailed(
    songID: String,
    message: String,
    timestamp: String
  ) {
    syncedCollections = syncedCollections.map { collection in
      WatchSyncCollection(
        id: collection.id,
        title: collection.title,
        kind: collection.kind,
        songs: collection.songs.map { song in
          guard song.id == songID else { return song }
          return song.withTransferState(.failed)
        }
      )
    }
    lastMessage = message
    lastUpdated = timestamp
    persistSyncedCollections()
  }

  var allSyncedSongs: [WatchSyncSong] {
    var orderedSongs = [WatchSyncSong]()
    var knownSongIDs = Set<String>()
    for collection in syncedCollections {
      for song in collection.songs where !knownSongIDs.contains(song.id) {
        orderedSongs.append(song)
        knownSongIDs.insert(song.id)
      }
    }
    return orderedSongs
  }

  private func referencedSongIDs(in collections: [WatchSyncCollection]) -> Set<String> {
    Set(collections.flatMap(\.referencedSongIDs))
  }

  private func cleanupOrphanedFiles(
    removedSongIDs: Set<String>,
    existingSongsByID: [String: WatchSyncSong]
  ) {
    guard !removedSongIDs.isEmpty else { return }
    for songID in removedSongIDs {
      guard let localFileName = existingSongsByID[songID]?.localFileName,
            let directoryURL = watchSongsDirectoryURL()
      else { continue }
      let fileURL = directoryURL.appendingPathComponent(localFileName, isDirectory: false)
      try? FileManager.default.removeItem(at: fileURL)
    }
  }

  private func persistSyncedCollections() {
    let collectionDictionaries = syncedCollections.map(\.dictionary)
    UserDefaults.standard.set(collectionDictionaries, forKey: watchSyncedCollectionsDefaultsKey)
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

  func song(withID id: String?) -> WatchSyncSong? {
    guard let id else { return nil }
    return allSyncedSongs.first { $0.id == id }
  }

  nonisolated private static func loadPersistedCollections() -> [WatchSyncCollection] {
    if let collectionDictionaries = UserDefaults.standard.array(
      forKey: watchSyncedCollectionsDefaultsKey
    ) as? [[String: Any]] {
      return collectionDictionaries.compactMap(WatchSyncCollection.init)
    }

    guard let songDictionaries = UserDefaults.standard.array(
      forKey: watchLegacySyncedSongsDefaultsKey
    ) as? [[String: Any]]
    else { return [] }

    let songs = songDictionaries.compactMap(WatchSyncSong.init)
    guard !songs.isEmpty else { return [] }
    return [
      WatchSyncCollection(
        id: WatchSyncCollection.miscID,
        title: WatchSyncCollection.miscTitle,
        kind: .misc,
        songs: songs
      ),
    ]
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
