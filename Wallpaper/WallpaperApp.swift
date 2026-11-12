//
//  WallpaperApp.swift
//  Wallpaper
//
//  Created by Jeff on 2026-11-05.
//

import AppKit
import SwiftUI

@main
struct WallpaperApp: App {
    @NSApplicationDelegateAdaptor(LiveDeskAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("LiveDesk") {
            ContentView(desktop: appDelegate.desktop)
        }
    }
}

@MainActor
final class LiveDeskAppDelegate: NSObject, NSApplicationDelegate {
    let desktop = DesktopWallpaperController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        desktop.restoreIfNeeded()
    }
}
