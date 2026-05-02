import Combine
import Foundation
import OSLog
import WatchConnectivity

@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
  let objectWillChange = ObservableObjectPublisher()

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

  private let log = OSLog(subsystem: "Muzify", category: "WatchConnectivity")
  private let session: WCSession?

  override init() {
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

    session.activate()
    refreshConnectionState(using: session)
  }

  func requestPhonePing() {
    guard let session else {
      lastMessage = "WatchConnectivity unavailable"
      return
    }
    guard session.isReachable else {
      lastMessage = "Phone not reachable"
      refreshConnectionState(using: session)
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
    if let type = payload[WatchTransferPayload.typeKey] as? String {
      activationStateDescription = type
    }
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
