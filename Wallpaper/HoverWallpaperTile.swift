import AVFoundation
import SwiftUI

struct HoverWallpaperTile<Artwork: View>: View {
    let title: String
    let videoURL: URL?
    @ViewBuilder let artwork: () -> Artwork
    @State private var isHovered = false
    @State private var preview: HoverVideoPlayback?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13)
        artwork()
            .overlay {
                if let preview {
                    HoverVideoLayer(player: preview.player)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isHovered {
                    Text(title)
                        .font(.custom("InterVariable", size: 13, relativeTo: .subheadline).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 26)
                        .padding([.horizontal, .bottom], 12)
                        .background {
                            LinearGradient(colors: [.clear, .black.opacity(0.86)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(GalleryStyle.border).allowsHitTesting(false) }
            .contentShape(shape)
            .onHover { hovered in
                isHovered = hovered
                if !hovered { stopPreview() }
            }
            .onDisappear {
                isHovered = false
                stopPreview()
            }
            .task(id: isHovered ? videoURL : nil) {
                stopPreview()
                guard isHovered, let videoURL else { return }
                do {
                    try await Task.sleep(for: .milliseconds(140))
                    let playback = try await HoverVideoPlayback.load(videoURL)
                    try Task.checkCancellation()
                    guard isHovered else { return }
                    preview = playback
                    playback.player.play()
                } catch {
                    // The thumbnail remains visible while playback is unavailable.
                }
            }
    }

    private func stopPreview() {
        preview?.player.pause()
        preview = nil
    }
}

private final class HoverVideoPlayback {
    let player = AVQueuePlayer()
    private let looper: AVPlayerLooper

    private init(asset: AVURLAsset, duration: CMTime) {
        player.isMuted = true
        let previewDuration = CMTimeMinimum(duration, CMTime(seconds: 6, preferredTimescale: 600))
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset),
                                timeRange: CMTimeRange(start: .zero, duration: previewDuration))
    }

    static func load(_ url: URL) async throws -> HoverVideoPlayback {
        let asset = AVURLAsset(url: url)
        let (duration, isPlayable) = try await asset.load(.duration, .isPlayable)
        guard isPlayable, duration.seconds.isFinite, duration.seconds > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        return HoverVideoPlayback(asset: asset, duration: duration)
    }
}

private struct HoverVideoLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }

    final class PlayerView: NSView {
        override func makeBackingLayer() -> CALayer {
            let layer = AVPlayerLayer()
            layer.videoGravity = .resizeAspectFill
            return layer
        }
    }
}
