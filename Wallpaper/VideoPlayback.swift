import Foundation
import AVFoundation

struct VideoSelection {
    let id = UUID()
    let url: URL
}

final class VideoPlayback {
    let id = UUID()
    let sourceURL: URL
    let previewPlayer: AVQueuePlayer
    let desktopPlayer: AVQueuePlayer
    let videoSize: CGSize
    private let previewLooper: AVPlayerLooper
    private let desktopLooper: AVPlayerLooper
    private let scopedURL: URL?

    private init(asset: AVURLAsset, sourceURL: URL, videoSize: CGSize, scopedURL: URL?) {
        self.sourceURL = sourceURL
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
            return VideoPlayback(asset: asset, sourceURL: url, videoSize: videoSize, scopedURL: scopedURL)
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

