//
//  ContentView.swift
//  Wallpaper
//
//  Created by Jeff on 2026-11-05.
//

import SwiftUI
import AVKit
import AppKit
import CoreGraphics

struct ContentView: View {
    let welcomeMessage = "Your desktop, in motion"
    @State private var player: AVPlayer? = nil
    @State private var looper: AVPlayerLooper? = nil
    @State private var desktopWindow: NSWindow? = nil
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(welcomeMessage)
            VideoPlayer(player: player)
            Button("Test Desktop Window") {
                if let screen = NSScreen.main{
                    let rect = screen.frame
                    let window = NSWindow(
                        contentRect: rect,
                        styleMask: .borderless,
                        backing: .buffered,
                        defer: false
                    )
                    window.backgroundColor = .systemBlue
                    let videoLayer = AVPlayerLayer(player: player)
                    let videoView = NSView(frame: NSRect(origin: .zero, size: rect.size))
                    videoView.layer = videoLayer
                    videoView.wantsLayer = true
                    window.contentView = videoView
                    desktopWindow = window
                    let iconLevel = CGWindowLevelForKey(.desktopIconWindow)
                    window.level = NSWindow.Level(rawValue: Int(iconLevel) - 1)
                    window.orderFront(nil)
                }
                
            }
        }
        .padding()
        .onAppear {
            let videoURL = Bundle.main.url(forResource: "sample", withExtension: "mp4")
            if let url = videoURL {
                let item = AVPlayerItem(url: url)
                let queuePlayer = AVQueuePlayer()
                looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
                player = queuePlayer
                player?.isMuted = true
                player?.play()
            }
        }
    }
}

#Preview {
    ContentView()
}
