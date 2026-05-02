//
//  MuzifyWatchAppApp.swift
//  MuzifyWatchApp Watch App
//
//  Created by Kaelan Willauer on 5/2/26.
//  Copyright © 2026 Maximilian Bauer. All rights reserved.
//

import SwiftUI

@main
struct MuzifyWatchApp_Watch_AppApp: App {
  @StateObject
  private var watchSessionManager = WatchSessionManager()
  @StateObject
  private var watchPlaybackManager = WatchPlaybackManager()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(watchSessionManager)
        .environmentObject(watchPlaybackManager)
        .task {
          watchSessionManager.activate()
        }
    }
  }
}
