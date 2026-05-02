import Foundation

enum WatchTransferPayload {
  static let typeKey = "type"
  static let appNameKey = "appName"
  static let timestampKey = "timestamp"
  static let messageKey = "message"
  static let isReachableKey = "isReachable"
  static let sourceKey = "source"
}

enum WatchTransferPayloadType: String {
  case stateSnapshot
  case ping
  case pingReply
}
