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
                player = AVPlayer(url: url)
                player?.isMuted = true
                player?.play()
            }
        }
    }
}

#Preview {
    ContentView()
}
