//
//  ContentView.swift
//  Wallpaper
//
//  Created by Jeff on 2026-11-05.
//

import SwiftUI
import AVKit

struct ContentView: View {
    let welcomeMessage = "Your desktop, in motion"
    @State private var player: AVPlayer? = nil
    @State private var looper: AVPlayerLooper? = nil
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(welcomeMessage)
            VideoPlayer(player: player)
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
