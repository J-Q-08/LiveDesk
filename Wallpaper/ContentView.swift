//
//  ContentView.swift
//  Wallpaper
//
//  Created by Jeff on 2026-11-05.
//

import SwiftUI

struct ContentView: View {
    let welcomeMessage = "Your desktop, in motion"
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(welcomeMessage)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
