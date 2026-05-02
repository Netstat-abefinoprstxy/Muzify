import AmperfyKit
import Foundation
import OSLog
import WatchConnectivity

private let phoneSyncedSongsDefaultsKey = "WatchConnectivity.syncedSongs"

@MainActor
final class PhoneWatchSessionManager: NSObject {
  nonisolated private static let log = OSLog(
    subsystem: "Amperfy",
    category: "WatchConnectivity"
  )
  private let session: WCSession?
  private var syncedSongs: [WatchSyncSong]

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

    let syncedSong = WatchSyncSong(song: song)
    syncedSongs.removeAll { $0.id == syncedSong.id }
    syncedSongs.insert(syncedSong, at: 0)
    persistSyncedSongs()

    let message = "Added \(song.title) to the watch sync list."
    guard let session, session.activationState == .activated else {
      return message
    }

    persistPayloadToApplicationContext([
      WatchTransferPayload.typeKey: WatchTransferPayloadType.songLibrarySync.rawValue,
      WatchTransferPayload.messageKey: "Updated watch library with \(song.title)",
      WatchTransferPayload.timestampKey: syncedSong.syncedAt,
    ])
    return "Updated the watch library with \(song.title)."
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
      WatchTransferPayload.songsKey: syncedSongs.map(\.dictionary),
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

  private func persistSyncedSongs() {
    UserDefaults.standard.set(
      syncedSongs.map(\.dictionary),
      forKey: phoneSyncedSongsDefaultsKey
    )
  }

  nonisolated private static func loadPersistedSongs() -> [WatchSyncSong] {
    guard let songDictionaries = UserDefaults.standard.array(
      forKey: phoneSyncedSongsDefaultsKey
    ) as? [[String: Any]]
    else { return [] }

    return songDictionaries.compactMap(WatchSyncSong.init)
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
