//
//  WallpaperApp.swift
//  Wallpaper
//
//  Created by Jeff on 2026-11-05.
//

import SwiftUI

@main
struct WallpaperApp: App {
    @StateObject private var desktop = DesktopWallpaperController()

    var body: some Scene {
        WindowGroup("LiveDesk") {
            ContentView(desktop: desktop)
        }
    }
}
