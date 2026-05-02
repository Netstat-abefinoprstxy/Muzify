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
}

enum WatchTransferPayloadType: String {
  case stateSnapshot
  case ping
  case pingReply
  case songLibrarySync
}

struct WatchSyncSong: Identifiable, Equatable {
  let id: String
  let title: String
  let artist: String
  let album: String
  let duration: Int
  let syncedAt: String

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
  }
}
