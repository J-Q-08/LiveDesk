//
//  ContentView.swift
//  Wallpaper
//
//  Created by Jeff on 2026-11-05.
//

import SwiftUI
import AVFoundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

struct ContentView: View {
    let welcomeMessage = "Your desktop, in motion"
    @State private var playback: VideoPlayback?
    @State private var desktopWindow: NSWindow? = nil
    @State private var showVideoPicker: Bool = false
    @State private var selectedVideo: VideoSelection?
    @State private var videoError: String?
    @State private var videoLayout: VideoLayout = .fill
    @State private var displayConfiguration = 0

    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text(welcomeMessage)
            VideoCanvas(player: playback?.previewPlayer, videoSize: playback?.videoSize ?? .zero,
                        videoLayout: videoLayout, isPreview: true)
                .frame(height: 260)
                .id("\(displayConfiguration)-\(playback?.id.uuidString ?? "none")")
            Picker("Video layout", selection: $videoLayout) {
                ForEach(VideoLayout.allCases) { layout in
                    Text(layout.rawValue).tag(layout)
                }
            }
            Button("Test Desktop Window") {
                if let screen = NSScreen.main, let playback, desktopWindow == nil {
                    let rect = screen.frame
                    let window = NSWindow(
                        contentRect: rect,
                        styleMask: .borderless,
                        backing: .buffered,
                        defer: false
                    )
                    let videoView = VideoCanvasView(frame: NSRect(origin: .zero, size: rect.size))
                    videoView.autoresizingMask = [.width, .height]
                    videoView.configure(player: playback.desktopPlayer, videoSize: playback.videoSize,
                                        layout: videoLayout, isPreview: false)
                    window.contentView = videoView
                    window.setFrame(screen.frame, display: true)
                    desktopWindow = window
                    let iconLevel = CGWindowLevelForKey(.desktopIconWindow)
                    window.level = NSWindow.Level(rawValue: Int(iconLevel) - 1)
                    window.orderFront(nil)
                }
            }
            .disabled(playback == nil || desktopWindow != nil)
            Button("Change Video") {
                showVideoPicker = true
            }
            if let videoError {
                Text(videoError)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displayConfiguration += 1
            guard let window = desktopWindow, let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.frame, display: true)
            (window.contentView as? VideoCanvasView)?.refreshGeometry()
        }
        .onChange(of: videoLayout) { _, newLayout in
            if let videoView = desktopWindow?.contentView as? VideoCanvasView {
                videoView.configure(player: playback?.desktopPlayer, videoSize: playback?.videoSize ?? .zero,
                                    layout: newLayout, isPreview: false)
            }
        }
        .fileImporter(
            isPresented: $showVideoPicker,
            allowedContentTypes: [.movie]
        ) { result in
            switch result {
            case .success(let url):
                videoError = nil
                selectedVideo = VideoSelection(url: url)
            case .failure(let error):
                videoError = "Couldn’t select a video: \(error.localizedDescription)"
            }
        }
        .task(id: selectedVideo?.id) {
            let selection = selectedVideo
            guard let url = selection?.url ?? Bundle.main.url(forResource: "sample", withExtension: "mp4") else {
                videoError = "Couldn’t find the bundled sample. Choose a video to play."
                return
            }

            do {
                let next = try await VideoPlayback.load(url, requiresFileAccess: selection != nil)
                try Task.checkCancellation()
                let previous = playback
                if let videoView = desktopWindow?.contentView as? VideoCanvasView {
                    videoView.configure(player: next.desktopPlayer, videoSize: next.videoSize,
                                        layout: videoLayout, isPreview: false)
                }
                playback = next
                videoError = nil
                next.previewPlayer.play()
                next.desktopPlayer.play()
                previous?.previewPlayer.pause()
                previous?.desktopPlayer.pause()
            } catch {
                guard !Task.isCancelled else { return }
                videoError = "Couldn’t play \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}

private enum VideoLayout: String, CaseIterable, Identifiable {
    case fit = "Fit"
    case fill = "Fill"
    case stretch = "Stretch"
    case center = "Center"
    case tile = "Tile"

    var id: String { rawValue }
}

private struct VideoCanvas: NSViewRepresentable {
    let player: AVPlayer?
    let videoSize: CGSize
    let videoLayout: VideoLayout
    let isPreview: Bool

    func makeNSView(context: Context) -> VideoCanvasView { VideoCanvasView() }

    func updateNSView(_ view: VideoCanvasView, context: Context) {
        view.configure(player: player, videoSize: videoSize,
                       layout: videoLayout, isPreview: isPreview)
    }
}

private final class VideoCanvasView: NSView {
    private let verticalTiles = CAReplicatorLayer()
    private let horizontalTiles = CAReplicatorLayer()
    private let videoLayer = AVPlayerLayer()
    private var videoSize: CGSize = .zero
    private var videoLayout: VideoLayout = .fill
    private var isPreview = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(verticalTiles)
        verticalTiles.addSublayer(horizontalTiles)
        horizontalTiles.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func configure(player: AVPlayer?, videoSize: CGSize, layout: VideoLayout, isPreview: Bool) {
        videoLayer.player = player
        self.videoSize = videoSize
        videoLayout = layout
        self.isPreview = isPreview
        updateGeometry()
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    func refreshGeometry() { updateGeometry() }

    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let screen = window?.screen ?? NSScreen.main
        let screenSize = screen?.frame.size ?? bounds.size
        let previewScale = isPreview
            ? min(bounds.width / screenSize.width, bounds.height / screenSize.height)
            : 1.0
        let canvasSize = isPreview
            ? CGSize(width: screenSize.width * previewScale, height: screenSize.height * previewScale)
            : bounds.size
        let canvas = CGRect(x: (bounds.width - canvasSize.width) / 2,
                            y: (bounds.height - canvasSize.height) / 2,
                            width: canvasSize.width, height: canvasSize.height)
        let screenScale = screen?.backingScaleFactor ?? 1.0
        let tileSize = CGSize(width: videoSize.width / screenScale * previewScale,
                              height: videoSize.height / screenScale * previewScale)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        verticalTiles.frame = bounds
        horizontalTiles.frame = canvas
        verticalTiles.instanceCount = 1
        horizontalTiles.instanceCount = 1
        verticalTiles.instanceTransform = CATransform3DIdentity
        horizontalTiles.instanceTransform = CATransform3DIdentity

        switch videoLayout {
        case .fit:
            if videoLayer.superlayer !== horizontalTiles {
                horizontalTiles.addSublayer(videoLayer)
            }
            videoLayer.frame = horizontalTiles.bounds
            videoLayer.videoGravity = .resizeAspect
        case .fill:
            if videoLayer.superlayer !== horizontalTiles {
                horizontalTiles.addSublayer(videoLayer)
            }
            videoLayer.frame = horizontalTiles.bounds
            videoLayer.videoGravity = .resizeAspectFill
        case .stretch:
            // Use the view's full bounds so both axes match the display exactly.
            if videoLayer.superlayer !== layer {
                layer?.addSublayer(videoLayer)
            }
            videoLayer.frame = bounds
            videoLayer.videoGravity = .resize
        case .center, .tile:
            if videoLayer.superlayer !== horizontalTiles {
                horizontalTiles.addSublayer(videoLayer)
            }
            guard tileSize.width > 0, tileSize.height > 0 else {
                videoLayer.frame = .zero
                CATransaction.commit()
                return
            }
            videoLayer.videoGravity = .resize
            if videoLayout == .center {
                videoLayer.frame = CGRect(x: (canvas.width - tileSize.width) / 2,
                                          y: (canvas.height - tileSize.height) / 2,
                                          width: tileSize.width, height: tileSize.height)
            } else {
                let startX = (canvas.width - tileSize.width) / 2
                    - ceil(max(0, (canvas.width - tileSize.width) / 2) / tileSize.width) * tileSize.width
                let startY = (canvas.height - tileSize.height) / 2
                    - ceil(max(0, (canvas.height - tileSize.height) / 2) / tileSize.height) * tileSize.height
                videoLayer.frame = CGRect(origin: CGPoint(x: startX, y: startY), size: tileSize)
                horizontalTiles.instanceCount = max(1, Int(ceil((canvas.width - startX) / tileSize.width)))
                verticalTiles.instanceCount = max(1, Int(ceil((canvas.height - startY) / tileSize.height)))
                horizontalTiles.instanceTransform = CATransform3DMakeTranslation(tileSize.width, 0, 0)
                verticalTiles.instanceTransform = CATransform3DMakeTranslation(0, tileSize.height, 0)
            }
        }
        CATransaction.commit()
    }
}

private struct VideoSelection {
    let id = UUID()
    let url: URL
}

private final class VideoPlayback {
    let id = UUID()
    let previewPlayer: AVQueuePlayer
    let desktopPlayer: AVQueuePlayer
    let videoSize: CGSize
    private let previewLooper: AVPlayerLooper
    private let desktopLooper: AVPlayerLooper
    private let scopedURL: URL?

    private init(asset: AVURLAsset, videoSize: CGSize, scopedURL: URL?) {
        previewPlayer = AVQueuePlayer()
        desktopPlayer = AVQueuePlayer()
        previewPlayer.isMuted = true
        desktopPlayer.isMuted = true
        previewLooper = AVPlayerLooper(player: previewPlayer, templateItem: AVPlayerItem(asset: asset))
        desktopLooper = AVPlayerLooper(player: desktopPlayer, templateItem: AVPlayerItem(asset: asset))
        self.videoSize = videoSize
        self.scopedURL = scopedURL
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    static func load(_ url: URL, requiresFileAccess: Bool) async throws -> VideoPlayback {
        let scopedURL = requiresFileAccess ? url : nil
        if let scopedURL, !scopedURL.startAccessingSecurityScopedResource() {
            throw CocoaError(.fileReadNoPermission)
        }

        do {
            let asset = AVURLAsset(url: url)
            let (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard isPlayable, duration.seconds.isFinite, duration.seconds > 0,
                  let track = tracks.first else {
                throw PlaybackError.unsupportedVideo
            }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let orientedSize = CGRect(origin: .zero, size: naturalSize).applying(transform).size
            let videoSize = CGSize(width: abs(orientedSize.width), height: abs(orientedSize.height))
            guard videoSize.width > 0, videoSize.height > 0 else {
                throw PlaybackError.unsupportedVideo
            }
            try Task.checkCancellation()
            return VideoPlayback(asset: asset, videoSize: videoSize, scopedURL: scopedURL)
        } catch {
            scopedURL?.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    private enum PlaybackError: LocalizedError {
        case unsupportedVideo

        var errorDescription: String? {
            "Choose a playable video with a video track."
        }
    }
}

#Preview {
    ContentView()
}
