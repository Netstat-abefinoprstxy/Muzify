import AmperfyKit
import Foundation
import OSLog
import WatchConnectivity

private let phoneSyncedCollectionsDefaultsKey = "WatchConnectivity.syncedCollections"
private let phoneLegacySyncedSongsDefaultsKey = "WatchConnectivity.syncedSongs"

@MainActor
final class PhoneWatchSessionManager: NSObject {
  nonisolated private static let log = OSLog(
    subsystem: "Amperfy",
    category: "WatchConnectivity"
  )
  private let session: WCSession?
  private var syncedCollections: [WatchSyncCollection]

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

  var isSessionActivated: Bool {
    session?.activationState == .activated
  }

  func activate() {
    guard let session else {
      os_log("WatchConnectivity is not supported on this device", log: Self.log, type: .info)
      return
    }

    os_log("Activating WatchConnectivity session", log: Self.log, type: .info)
    session.activate()
  }

  func updateApplicationContext() {
    guard let session else { return }
    guard session.activationState == .activated else { return }

    do {
      try session.updateApplicationContext(createApplicationContextPayload(for: session))
      os_log("Updated watch application context", log: Self.log, type: .info)
    } catch {
      os_log(
        "Failed to update watch application context: %s",
        log: Self.log,
        type: .error,
        error.localizedDescription
      )
    }
  }

  func syncSongMetadata(_ song: Song) -> String {
    guard session != nil else {
      return "Watch sync is unavailable on this device."
    }

    guard let fileURL = localFileURL(for: song)
    else {
      return "Download this song on the iPhone before syncing it to the watch."
    }

    let previousReferencedSongIDs = referencedSongIDs(in: syncedCollections)
    let syncedSong = WatchSyncSong(song: song)
    let existingMiscSongs = collection(withID: WatchSyncCollection.miscID)?.songs ?? []
    let miscSongs = ([syncedSong] + existingMiscSongs)
      .reduce(into: [WatchSyncSong]()) { partialResult, song in
        if !partialResult.contains(where: { $0.id == song.id }) {
          partialResult.append(song)
        }
      }
    let miscCollection = WatchSyncCollection(
      id: WatchSyncCollection.miscID,
      title: WatchSyncCollection.miscTitle,
      kind: .misc,
      songs: miscSongs
    )
    syncedCollections = upserting(collection: miscCollection, into: syncedCollections)
    persistSyncedCollections()

    let message = "Queued \(song.title) for watch sync."
    guard let session, session.activationState == .activated else {
      return message
    }

    persistPayloadToApplicationContext([
      WatchTransferPayload.typeKey: WatchTransferPayloadType.songLibrarySync.rawValue,
      WatchTransferPayload.messageKey: "Queued \(song.title) for transfer",
      WatchTransferPayload.timestampKey: syncedSong.syncedAt,
    ])
    if !previousReferencedSongIDs.contains(syncedSong.id) {
      queueFileTransfer(for: syncedSong, fileURL: fileURL, session: session)
    }
    return "Queued \(song.title) for transfer to the watch."
  }

  func syncPlaylist(_ playlist: Playlist) -> String {
    guard session != nil else {
      return "Watch sync is unavailable on this device."
    }

    let songs = playlist.playables.compactMap(\.asSong)
    let cachedSongs = songs.compactMap { song -> (Song, URL)? in
      guard let fileURL = localFileURL(for: song) else { return nil }
      return (song, fileURL)
    }

    if cachedSongs.count != songs.count {
      let missingCount = songs.count - cachedSongs.count
      return "Download \(missingCount) missing song\(missingCount == 1 ? "" : "s") on the iPhone first."
    }

    let previousReferencedSongIDs = referencedSongIDs(in: syncedCollections)
    let playlistCollection = WatchSyncCollection(
      playlist: playlist,
      songs: cachedSongs.map(\.0)
    )
    syncedCollections = upserting(collection: playlistCollection, into: syncedCollections)
    persistSyncedCollections()

    guard let session, session.activationState == .activated else {
      return "Prepared \(playlist.name) for watch sync."
    }

    persistPayloadToApplicationContext([
      WatchTransferPayload.typeKey: WatchTransferPayloadType.songLibrarySync.rawValue,
      WatchTransferPayload.messageKey: "Synced playlist \(playlist.name)",
      WatchTransferPayload.timestampKey: ISO8601DateFormatter().string(from: Date()),
    ])

    let newlyReferencedSongIDs = referencedSongIDs(in: syncedCollections)
      .subtracting(previousReferencedSongIDs)
    for (song, fileURL) in cachedSongs where newlyReferencedSongIDs.contains(song.id) {
      queueFileTransfer(for: WatchSyncSong(song: song), fileURL: fileURL, session: session)
    }

    return "Synced playlist \(playlist.name) to the watch."
  }

  private func createApplicationContextPayload(
    for session: WCSession,
    overrides: [String: Any] = [:]
  ) -> [String: Any] {
    var payload: [String: Any] = [
      WatchTransferPayload.typeKey: WatchTransferPayloadType.stateSnapshot.rawValue,
      WatchTransferPayload.appNameKey: AppDelegate.name,
      WatchTransferPayload.timestampKey: ISO8601DateFormatter().string(from: Date()),
      WatchTransferPayload.isReachableKey: session.isReachable,
      WatchTransferPayload.sourceKey: "phone",
      WatchTransferPayload.collectionsKey: syncedCollections.map(\.dictionary),
    ]

    for (key, value) in overrides {
      payload[key] = value
    }

    return payload
  }

  private func persistPayloadToApplicationContext(_ overrides: [String: Any]) {
    guard let session, session.activationState == .activated else { return }
    do {
      try session.updateApplicationContext(createApplicationContextPayload(
        for: session,
        overrides: overrides
      ))
    } catch {
      os_log(
        "Failed to persist watch application context: %s",
        log: Self.log,
        type: .error,
        error.localizedDescription
      )
    }
  }

  private func persistSyncedCollections() {
    UserDefaults.standard.set(
      syncedCollections.map(\.dictionary),
      forKey: phoneSyncedCollectionsDefaultsKey
    )
  }

  private func referencedSongIDs(in collections: [WatchSyncCollection]) -> Set<String> {
    Set(collections.flatMap { $0.songs.map(\.id) })
  }

  private func collection(withID id: String) -> WatchSyncCollection? {
    syncedCollections.first { $0.id == id }
  }

  private func upserting(
    collection: WatchSyncCollection,
    into collections: [WatchSyncCollection]
  ) -> [WatchSyncCollection] {
    var updatedCollections = collections.filter { $0.id != collection.id }
    if collection.kind == .misc {
      updatedCollections.insert(collection, at: 0)
    } else {
      updatedCollections.append(collection)
    }
    return updatedCollections
  }

  private func localFileURL(for song: Song) -> URL? {
    guard let relFilePath = song.relFilePath,
          let fileURL = CacheFileManager.shared.getAbsoluteAmperfyPath(relFilePath: relFilePath),
          FileManager.default.fileExists(atPath: fileURL.path)
    else { return nil }
    return fileURL
  }

  private func queueFileTransfer(
    for syncedSong: WatchSyncSong,
    fileURL: URL,
    session: WCSession
  ) {
    cancelOutstandingTransfers(for: syncedSong.id, session: session)
    let fileMetadata = syncedSong.dictionary.merging([
      WatchTransferPayload.typeKey: WatchTransferPayloadType.songFileTransfer.rawValue,
      WatchTransferPayload.transferStateKey: "pending",
    ]) { _, newValue in newValue }
    session.transferFile(fileURL, metadata: fileMetadata)
  }

  private func cancelOutstandingTransfers(for songID: String, session: WCSession) {
    session.outstandingFileTransfers
      .filter { transfer in
        transfer.file.metadata?[WatchTransferPayload.songIDKey] as? String == songID
      }
      .forEach { $0.cancel() }
  }

  nonisolated private static func loadPersistedCollections() -> [WatchSyncCollection] {
    if let collectionDictionaries = UserDefaults.standard.array(
      forKey: phoneSyncedCollectionsDefaultsKey
    ) as? [[String: Any]] {
      return collectionDictionaries.compactMap(WatchSyncCollection.init)
    }

    guard let songDictionaries = UserDefaults.standard.array(
      forKey: phoneLegacySyncedSongsDefaultsKey
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

  nonisolated private static func createPingReplyPayload(
    incomingMessage: String,
    isReachable: Bool
  ) -> [String: Any] {
    [
      WatchTransferPayload.typeKey: WatchTransferPayloadType.pingReply.rawValue,
      WatchTransferPayload.appNameKey: AppDelegate.name,
      WatchTransferPayload.timestampKey: ISO8601DateFormatter().string(from: Date()),
      WatchTransferPayload.messageKey: "Reply from phone: \(incomingMessage)",
      WatchTransferPayload.isReachableKey: isReachable,
      WatchTransferPayload.sourceKey: "phone",
    ]
  }
}

extension PhoneWatchSessionManager: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    let isPaired = session.isPaired.description
    let isWatchAppInstalled = session.isWatchAppInstalled.description
    let isReachable = session.isReachable.description
    let errorDescription = error?.localizedDescription

    Task { @MainActor in
      if let errorDescription {
        os_log(
          "WatchConnectivity activation failed: %s",
          log: Self.log,
          type: .error,
          errorDescription
        )
      } else {
        os_log(
          "WatchConnectivity activated. Paired: %s, Watch installed: %s, Reachable: %s",
          log: Self.log,
          type: .info,
          isPaired,
          isWatchAppInstalled,
          isReachable
        )
        self.updateApplicationContext()
      }
    }
  }

  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
    Task { @MainActor in
      os_log("WatchConnectivity session became inactive", log: Self.log, type: .info)
    }
  }

  nonisolated func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
    Task { @MainActor in
      os_log("WatchConnectivity session deactivated", log: Self.log, type: .info)
    }
  }

  nonisolated func session(
    _ session: WCSession,
    didFinish fileTransfer: WCSessionFileTransfer,
    error: Error?
  ) {
    let title = fileTransfer.file.metadata?[WatchTransferPayload.songTitleKey] as? String ?? "-"
    let errorDescription = error?.localizedDescription

    Task { @MainActor in
      if let errorDescription {
        os_log(
          "Watch file transfer failed for %s: %s",
          log: Self.log,
          type: .error,
          title,
          errorDescription
        )
      } else {
        os_log(
          "Watch file transfer finished for %s",
          log: Self.log,
          type: .info,
          title
        )
      }
    }
  }

  nonisolated func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    let messageType = message[WatchTransferPayload.typeKey] as? String ?? "-"
    let incomingMessage = message[WatchTransferPayload.messageKey] as? String ?? "Ping"
    let isReachable = session.isReachable

    if messageType == WatchTransferPayloadType.ping.rawValue {
      let payload = Self.createPingReplyPayload(
        incomingMessage: incomingMessage,
        isReachable: isReachable
      )
      replyHandler(payload)
      Task { @MainActor in
        os_log(
          "Received watch message of type: %s",
          log: Self.log,
          type: .info,
          messageType
        )
        self.persistPayloadToApplicationContext(payload)
      }
    } else {
      replyHandler([:])
      Task { @MainActor in
        os_log(
          "Received watch message of type: %s",
          log: Self.log,
          type: .info,
          messageType
        )
      }
    }
  }
}
