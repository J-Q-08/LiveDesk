//
//  WallpaperApp.swift
//  Wallpaper
//
//  Created by Jeff on 2026-11-05.
//

import SwiftUI

@main
struct WallpaperApp: App {
    init() {
        LegacyDataMigration.run()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
