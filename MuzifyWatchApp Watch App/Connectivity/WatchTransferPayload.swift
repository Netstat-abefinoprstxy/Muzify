import Foundation

enum WatchTransferPayload {
  static let typeKey = "type"
  static let appNameKey = "appName"
  static let timestampKey = "timestamp"
  static let messageKey = "message"
  static let isReachableKey = "isReachable"
  static let sourceKey = "source"
  static let songsKey = "songs"
  static let songIDKey = "id"
  static let songTitleKey = "title"
  static let songArtistKey = "artist"
  static let songAlbumKey = "album"
  static let songDurationKey = "duration"
  static let songSyncedAtKey = "syncedAt"
  static let transferStateKey = "transferState"
  static let localFileNameKey = "localFileName"
}

enum WatchTransferPayloadType: String {
  case stateSnapshot
  case ping
  case pingReply
  case songLibrarySync
  case songFileTransfer
}

enum WatchSyncTransferState: String {
  case pending
  case transferred
  case failed
}

struct WatchSyncSong: Identifiable, Equatable {
  let id: String
  let title: String
  let artist: String
  let album: String
  let duration: Int
  let syncedAt: String
  let transferState: WatchSyncTransferState
  let localFileName: String?

  init?(_ dictionary: [String: Any]) {
    guard let id = dictionary[WatchTransferPayload.songIDKey] as? String,
          let title = dictionary[WatchTransferPayload.songTitleKey] as? String,
          let artist = dictionary[WatchTransferPayload.songArtistKey] as? String,
          let album = dictionary[WatchTransferPayload.songAlbumKey] as? String,
          let duration = dictionary[WatchTransferPayload.songDurationKey] as? Int,
          let syncedAt = dictionary[WatchTransferPayload.songSyncedAtKey] as? String
    else { return nil }

    self.id = id
    self.title = title
    self.artist = artist
    self.album = album
    self.duration = duration
    self.syncedAt = syncedAt
    transferState = WatchSyncTransferState(
      rawValue: dictionary[WatchTransferPayload.transferStateKey] as? String ?? ""
    ) ?? .pending
    localFileName = dictionary[WatchTransferPayload.localFileNameKey] as? String
  }

  var dictionary: [String: Any] {
    var payload: [String: Any] = [
      WatchTransferPayload.songIDKey: id,
      WatchTransferPayload.songTitleKey: title,
      WatchTransferPayload.songArtistKey: artist,
      WatchTransferPayload.songAlbumKey: album,
      WatchTransferPayload.songDurationKey: duration,
      WatchTransferPayload.songSyncedAtKey: syncedAt,
      WatchTransferPayload.transferStateKey: transferState.rawValue,
    ]
    if let localFileName {
      payload[WatchTransferPayload.localFileNameKey] = localFileName
    }
    return payload
  }

  func withTransferState(
    _ transferState: WatchSyncTransferState,
    localFileName: String? = nil
  ) -> WatchSyncSong {
    WatchSyncSong(
      id: id,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      syncedAt: syncedAt,
      transferState: transferState,
      localFileName: localFileName ?? self.localFileName
    )
  }

  private init(
    id: String,
    title: String,
    artist: String,
    album: String,
    duration: Int,
    syncedAt: String,
    transferState: WatchSyncTransferState,
    localFileName: String?
  ) {
    self.id = id
    self.title = title
    self.artist = artist
    self.album = album
    self.duration = duration
    self.syncedAt = syncedAt
    self.transferState = transferState
    self.localFileName = localFileName
  }
}
