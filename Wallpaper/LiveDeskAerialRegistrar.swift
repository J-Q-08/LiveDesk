// Adapted from CaveWall (MIT License, copyright 2026 Rishav Bairagya).
// See THIRD_PARTY_NOTICES.md for license and source.
import AppKit
import AVFoundation
import VideoToolbox

private final class AerialWriterPipeline: @unchecked Sendable {
    nonisolated(unsafe) let writerInput: AVAssetWriterInput
    nonisolated(unsafe) let readerOutput: AVAssetReaderTrackOutput
    nonisolated(unsafe) let writer: AVAssetWriter
    nonisolated let finished: CheckedContinuation<Void, Never>

    nonisolated init(writerInput: AVAssetWriterInput, readerOutput: AVAssetReaderTrackOutput,
                     writer: AVAssetWriter, finished: CheckedContinuation<Void, Never>) {
        self.writerInput = writerInput
        self.readerOutput = readerOutput
        self.writer = writer
        self.finished = finished
    }

    nonisolated func drain() {
        while writerInput.isReadyForMoreMediaData {
            guard let sample = readerOutput.copyNextSampleBuffer() else {
                writerInput.markAsFinished()
                writer.finishWriting { self.finished.resume() }
                return
            }
            guard writerInput.append(sample) else {
                writer.cancelWriting()
                finished.resume()
                return
            }
        }
    }
}

/// Registers videos in the private per-user Aerial catalog used by macOS Wallpaper.
enum LiveDeskAerialRegistrar {
    nonisolated private static let subcategoryID = "1DA60D58-7B3F-4A52-A441-879D57DD0002"
    @MainActor private static var isInstalling = false

    enum RegistrarError: LocalizedError {
        case installInProgress
        case manifestNotFound
        case thumbnailFailed
        case transcodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .installInProgress:
                "LiveDesk is already preparing a video for the Lock Screen."
            case .manifestNotFound:
                "The macOS Aerial catalog could not be read. Open Wallpaper settings and download an Apple Aerial first."
            case .thumbnailFailed:
                "Couldn’t generate a thumbnail from this video."
            case .transcodeFailed(let reason):
                "Couldn’t prepare this video for the Lock Screen: \(reason)"
            }
        }
    }

    /// Writes video-only Main10 HEVC with regular keyframes for the Aerial player.
    nonisolated private static func transcodeToHEVC(source: URL, destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RegistrarError.transcodeFailed("no video track in that file")
        }

        // Output size: cap the long edge at 1920 (a wallpaper doesn't need 4K).
        let (t, naturalSize, nominalFrameRate) = try await track.load(
            .preferredTransform, .naturalSize, .nominalFrameRate)
        let srcW = abs(naturalSize.width), srcH = abs(naturalSize.height)
        guard srcW.isFinite, srcH.isFinite, srcW > 0, srcH > 0 else {
            throw RegistrarError.transcodeFailed("invalid video dimensions")
        }
        let scale = min(1.0, 1920.0 / max(srcW, srcH))
        let outW = max(2, Int((srcW * scale / 2).rounded()) * 2)   // even dimensions
        let outH = max(2, Int((srcH * scale / 2).rounded()) * 2)
        let fps = nominalFrameRate > 0 ? Int(nominalFrameRate.rounded()) : 30

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            // 10-bit pixel buffers → the HEVC encoder produces Main10, which the
            // aerial renderer needs (8-bit renders black).
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw RegistrarError.transcodeFailed("reader setup failed") }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: 12_000_000,
            AVVideoMaxKeyFrameIntervalKey: fps,          // a keyframe about every second
            AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            AVVideoAllowFrameReorderingKey: false,       // no B-frames → clean seeks
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: compression
        ])
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = t
        guard writer.canAdd(writerInput) else { throw RegistrarError.transcodeFailed("writer setup failed") }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            throw RegistrarError.transcodeFailed(
                writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "start failed")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "LiveDesk.AerialTranscode")
        await withCheckedContinuation { finished in
            let pipeline = AerialWriterPipeline(writerInput: writerInput, readerOutput: readerOutput,
                                                writer: writer, finished: finished)
            writerInput.requestMediaDataWhenReady(on: queue) {
                pipeline.drain()
            }
        }

        guard writer.status == .completed, reader.status == .completed else {
            throw RegistrarError.transcodeFailed(
                writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "encode failed")
        }
    }

    @MainActor static func install(videoURL: URL, title: String, libraryID: String, in store: URL) async throws -> String {
        guard !isInstalling else { throw RegistrarError.installInProgress }
        isInstalling = true
        defer { isInstalling = false }

        let aerials = store.appendingPathComponent("aerials", isDirectory: true)
        let manifest = aerials.appendingPathComponent("manifest/entries.json")
        guard FileManager.default.isReadableFile(atPath: manifest.path) else {
            throw RegistrarError.manifestNotFound
        }

        let files = FileManager.default
        let existing = try Data(contentsOf: manifest)
        guard let catalog = try JSONSerialization.jsonObject(with: existing) as? [String: Any],
              let assets = catalog["assets"] as? [[String: Any]] else {
            throw RegistrarError.manifestNotFound
        }
        if let registered = assets.first(where: { asset in
            guard asset["liveDeskLibraryID"] as? String == libraryID,
                  asset["localizedNameKey"] as? String == title,
                  let id = asset["id"] as? String, UUID(uuidString: id) != nil else { return false }
            return files.isReadableFile(atPath: aerials.appendingPathComponent("videos/\(id).mov").path) &&
                files.isReadableFile(atPath: aerials.appendingPathComponent("thumbnails/\(id).png").path)
        }), let id = registered["id"] as? String { return id }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        guard let frame = try? await generator.image(at: .zero).image,
              let thumbnail = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) else {
            throw RegistrarError.thumbnailFailed
        }

        let assetID = UUID().uuidString
        let video = aerials.appendingPathComponent("videos/\(assetID).mov")
        let preview = aerials.appendingPathComponent("thumbnails/\(assetID).png")
        try files.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            try await transcodeToHEVC(source: videoURL, destination: video)
            try thumbnail.write(to: preview, options: .atomic)

            let original = try Data(contentsOf: manifest)
            guard var catalog = try JSONSerialization.jsonObject(with: original) as? [String: Any],
                  var categories = catalog["categories"] as? [[String: Any]],
                  var assets = catalog["assets"] as? [[String: Any]] else {
                throw RegistrarError.manifestNotFound
            }
            let backup = manifest.appendingPathExtension("livedesk-backup")
            if !files.fileExists(atPath: backup.path) {
                try original.write(to: backup, options: .atomic)
            }

            let group: [String: Any] = [
                "localizedNameKey": "LiveDesk",
                "localizedDescriptionKey": "Live wallpapers from LiveDesk",
                "previewImage": preview.absoluteString,
                "representativeAssetID": assetID,
                "preferredOrder": 99
            ]
            var category = group
            var subcategory = group
            category["id"] = AerialSelection.categoryID
            subcategory["id"] = subcategoryID
            category["subcategories"] = [subcategory]
            categories.removeAll { $0["id"] as? String == AerialSelection.categoryID }
            categories.append(category)

            // Retain earlier registrations so an existing macOS selection still resolves.
            assets.append([
                "id": assetID,
                "liveDeskLibraryID": libraryID,
                "shotID": "LIVEDESK_\(assetID)",
                "localizedNameKey": title,
                "accessibilityLabel": title,
                "previewImage": preview.absoluteString,
                "url-4K-SDR-240FPS": video.absoluteString,
                "categories": [AerialSelection.categoryID],
                "subcategories": [subcategoryID],
                "includeInShuffle": false,
                "showInTopLevel": true,
                "preferredOrder": 0,
                "pointsOfInterest": ["0": "LIVEDESK_\(assetID)_0"]
            ])
            catalog["categories"] = categories
            catalog["assets"] = assets
            try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted])
                .write(to: manifest, options: .atomic)
            return assetID
        } catch {
            try? files.removeItem(at: video)
            try? files.removeItem(at: preview)
            throw error
        }
    }
}
