import SwiftUI

struct ContentView: View {
  @EnvironmentObject
  private var watchSessionManager: WatchSessionManager

  var body: some View {
    List {
      Section("Muzify Watch") {
        Label("Connectivity Ready", systemImage: "applewatch.radiowaves.left.and.right")
      }

      Section("Session") {
        keyValueRow(label: "State", value: watchSessionManager.activationStateDescription)
        keyValueRow(label: "Reachable", value: watchSessionManager.isReachable.description)
        keyValueRow(
          label: "Companion Installed",
          value: watchSessionManager.isCompanionAppInstalled.description
        )
      }

      Section("Last Update") {
        Text(watchSessionManager.lastMessage)
        Text(watchSessionManager.lastUpdated)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section {
        Button("Ping Phone") {
          watchSessionManager.requestPhonePing()
        }
      }
    }
    .listStyle(.carousel)
  }

  @ViewBuilder
  private func keyValueRow(label: String, value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
    }
  }
}

#Preview {
  ContentView()
    .environmentObject(WatchSessionManager())
}
