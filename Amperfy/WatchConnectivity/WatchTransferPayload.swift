import AmperfyKit
import Foundation

enum WatchTransferPayload {
  static let typeKey = "type"
  static let appNameKey = "appName"
  static let timestampKey = "timestamp"
  static let messageKey = "message"
  static let isReachableKey = "isReachable"
  static let sourceKey = "source"
  static let collectionsKey = "collections"
  static let collectionIDKey = "collectionID"
  static let collectionTitleKey = "collectionTitle"
  static let collectionKindKey = "collectionKind"
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

enum WatchSyncCollectionKind: String {
  case misc
  case playlist
}

struct WatchSyncSong: Identifiable, Equatable {
  let id: String
  let title: String
  let artist: String
  let album: String
  let duration: Int
  let syncedAt: String

  init(song: Song, syncedAt: String = ISO8601DateFormatter().string(from: Date())) {
    id = song.id
    title = song.title
    artist = song.creatorName
    album = song.album?.name ?? ""
    duration = song.duration
    self.syncedAt = syncedAt
  }

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

  var dictionary: [String: Any] {
    [
      WatchTransferPayload.songIDKey: id,
      WatchTransferPayload.songTitleKey: title,
      WatchTransferPayload.songArtistKey: artist,
      WatchTransferPayload.songAlbumKey: album,
      WatchTransferPayload.songDurationKey: duration,
      WatchTransferPayload.songSyncedAtKey: syncedAt,
    ]
  }
}

struct WatchSyncCollection: Identifiable, Equatable {
  static let miscID = "misc"
  static let miscTitle = "Misc"

  let id: String
  let title: String
  let kind: WatchSyncCollectionKind
  let songs: [WatchSyncSong]

  init(id: String, title: String, kind: WatchSyncCollectionKind, songs: [WatchSyncSong]) {
    self.id = id
    self.title = title
    self.kind = kind
    self.songs = songs
  }

  init(song: Song) {
    self.init(
      id: Self.miscID,
      title: Self.miscTitle,
      kind: .misc,
      songs: [WatchSyncSong(song: song)]
    )
  }

  init(playlist: Playlist, songs: [Song]) {
    self.init(
      id: playlist.id,
      title: playlist.name,
      kind: .playlist,
      songs: songs.map { WatchSyncSong(song: $0) }
    )
  }

  init?(_ dictionary: [String: Any]) {
    guard let id = dictionary[WatchTransferPayload.collectionIDKey] as? String,
          let title = dictionary[WatchTransferPayload.collectionTitleKey] as? String,
          let kindRawValue = dictionary[WatchTransferPayload.collectionKindKey] as? String,
          let kind = WatchSyncCollectionKind(rawValue: kindRawValue),
          let songDictionaries = dictionary[WatchTransferPayload.songsKey] as? [[String: Any]]
    else { return nil }

    self.id = id
    self.title = title
    self.kind = kind
    songs = songDictionaries.compactMap(WatchSyncSong.init)
  }

  var dictionary: [String: Any] {
    [
      WatchTransferPayload.collectionIDKey: id,
      WatchTransferPayload.collectionTitleKey: title,
      WatchTransferPayload.collectionKindKey: kind.rawValue,
      WatchTransferPayload.songsKey: songs.map(\.dictionary),
    ]
  }

  var referencedSongIDs: Set<String> {
    Set(songs.map(\.id))
  }
}
