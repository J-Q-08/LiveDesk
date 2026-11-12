// Adapted from CaveWall (MIT License, copyright 2026 Rishav Bairagya).
// See THIRD_PARTY_NOTICES.md for license and source.
import AppKit
import AVFoundation
import VideoToolbox

private final class AerialWriterPipeline: @unchecked Sendable {
    nonisolated(unsafe) let writerInput: AVAssetWriterInput
    nonisolated(unsafe) let readerOutput: AVAssetReaderTrackOutput
    nonisolated(unsafe) let writer: AVAssetWriter
    nonisolated let finished: DispatchSemaphore

    nonisolated init(writerInput: AVAssetWriterInput, readerOutput: AVAssetReaderTrackOutput,
                     writer: AVAssetWriter, finished: DispatchSemaphore) {
        self.writerInput = writerInput
        self.readerOutput = readerOutput
        self.writer = writer
        self.finished = finished
    }

    nonisolated func drain() {
        while writerInput.isReadyForMoreMediaData {
            if let sample = readerOutput.copyNextSampleBuffer() {
                if !writerInput.append(sample) {
                    writerInput.markAsFinished()
                    writer.finishWriting { self.finished.signal() }
                    break
                }
            } else {
                writerInput.markAsFinished()
                writer.finishWriting { self.finished.signal() }
                break
            }
        }
    }
}

/// Registers LiveDesk's active video wallpaper as a private macOS "Aerial"
/// wallpaper category (a "LiveDesk" section in System Settings > Wallpaper),
/// using undocumented wallpaper data. Backdrop does not publish its implementation.
///
/// This is NOT a public Apple API. It edits a private per-user manifest
/// (~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json)
/// that Apple's own WallpaperAgent reads. It can stop working on any macOS
/// update with no warning — there is no entitlement or documented interface
/// for this. Everything lives under the user's own Library, so it needs no
/// elevated privileges and can't affect other users or system files outside
/// that folder.
enum LiveDeskAerialRegistrar {

    // The category/subcategory are fixed (one "LiveDesk" section in Settings).
    // The ASSET id rotates on every video change: macOS caches aerial video by
    // asset id, so reusing an id with new content renders a stale/black frame.
    // A fresh id per change forces a clean reload.
    nonisolated private static let categoryID = "1DA60D58-7B3F-4A52-A441-879D57DD0001"
    nonisolated private static let subcategoryID = "1DA60D58-7B3F-4A52-A441-879D57DD0002"

    nonisolated private static let assetKey = "livedesk.aerialAssetID"
    /// The asset id currently registered (nil until the first register).
    nonisolated private static var currentAssetID: String? {
        get { UserDefaults.standard.string(forKey: assetKey) }
        set { UserDefaults.standard.set(newValue, forKey: assetKey) }
    }

    nonisolated private static var aerialsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apple.wallpaper/aerials", isDirectory: true)
    }
    nonisolated private static var manifestURL: URL { aerialsDir.appendingPathComponent("manifest/entries.json") }
    nonisolated private static func videoFile(for id: String) -> URL { aerialsDir.appendingPathComponent("videos/\(id).mov") }
    nonisolated private static func thumbFile(for id: String) -> URL { aerialsDir.appendingPathComponent("thumbnails/\(id).png") }

    /// The private store macOS reads to decide the active wallpaper + screensaver.
    nonisolated private static var indexURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apple.wallpaper/Store/Index.plist")
    }

    enum RegistrarError: LocalizedError {
        case manifestNotFound
        case thumbnailFailed
        case transcodeFailed(String)
        case backupMissing
        case ioError(Error)

        var errorDescription: String? {
            switch self {
            case .manifestNotFound:
                return "macOS's private wallpaper manifest wasn't found on this system — nothing to register into."
            case .thumbnailFailed:
                return "Couldn't generate a thumbnail from that video."
            case .transcodeFailed(let reason):
                return "Couldn't convert that video to HEVC: \(reason)"
            case .backupMissing:
                return "The previous wallpaper backup is missing. LiveDesk left the current wallpaper unchanged."
            case .ioError(let e):
                return e.localizedDescription
            }
        }
    }

    /// Transcodes to an Aerial-compatible HEVC that plays cleanly on LOOP and
    /// re-activation. Apple's aerials share three properties a plain export
    /// doesn't guarantee, and whose absence makes the video render BLACK the
    /// second time macOS shows it:
    ///   1. HEVC (hvc1) — H.264 renders black outright.
    ///   2. **10-bit (Main10)** — 8-bit content renders black in the aerial path.
    ///   3. Frequent keyframes + NO B-frame reordering — so seeking back to
    ///      frame 0 (what looping / re-activation does) lands on a clean keyframe.
    ///   4. Video-only (no audio track).
    /// AVAssetWriter gives us that control; AVAssetExportSession presets don't.
    nonisolated private static func transcodeToHEVC(source: URL, destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RegistrarError.transcodeFailed("no video track in that file")
        }

        // Output size: cap the long edge at 1920 (a wallpaper doesn't need 4K).
        let (t, naturalSize, nominalFrameRate) = try await track.load(
            .preferredTransform, .naturalSize, .nominalFrameRate)
        let displayed = naturalSize.applying(t)
        let srcW = abs(displayed.width), srcH = abs(displayed.height)
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

        let sem = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "com.pixelcave.LiveDesk.transcode")
        let pipeline = AerialWriterPipeline(writerInput: writerInput, readerOutput: readerOutput,
                                            writer: writer, finished: sem)
        writerInput.requestMediaDataWhenReady(on: queue) {
            pipeline.drain()
        }
        DispatchQueue.global(qos: .utility).sync { sem.wait() }

        if writer.status != .completed {
            throw RegistrarError.transcodeFailed(writer.error?.localizedDescription ?? "encode failed")
        }
    }

    /// True once LiveDesk's category is present in the manifest.
    nonisolated static var isRegistered: Bool {
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let categories = json["categories"] as? [[String: Any]]
        else { return false }
        return categories.contains { ($0["id"] as? String) == categoryID }
    }

    /// Copies `videoURL` into the private Aerials store under a FRESH asset id
    /// (so macOS reloads it instead of serving a cached/black frame), updates the
    /// "LiveDesk" category, and cleans up the previous asset. `setAsActiveLiveWallpaper`
    /// then points the live wallpaper at the new id.
    nonisolated static func register(videoURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RegistrarError.manifestNotFound
        }

        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 512, height: 512)
        guard let cg = try? await gen.image(at: .zero).image,
              let pngData = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { throw RegistrarError.thumbnailFailed }

        let fm = FileManager.default
        try fm.createDirectory(at: aerialsDir.appendingPathComponent("videos", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: aerialsDir.appendingPathComponent("thumbnails", isDirectory: true),
                               withIntermediateDirectories: true)
        let oldID = currentAssetID
        let newID = UUID().uuidString
        let newVideo = videoFile(for: newID)
        let newThumb = thumbFile(for: newID)

        do {
            try await transcodeToHEVC(source: videoURL, destination: newVideo)
            try pngData.write(to: newThumb, options: .atomic)

            // One-time backup of the untouched manifest, kept alongside it.
            let backupURL = manifestURL.deletingLastPathComponent()
                .appendingPathComponent("entries.json.livedesk-backup")
            if !fm.fileExists(atPath: backupURL.path) {
                try fm.copyItem(at: manifestURL, to: backupURL)
            }

            let data = try Data(contentsOf: manifestURL)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RegistrarError.manifestNotFound
            }
            var categories = json["categories"] as? [[String: Any]] ?? []
            var assets = json["assets"] as? [[String: Any]] ?? []

            let thumbURLString = "file://" + newThumb.path
            let videoURLString = "file://" + newVideo.path

            categories.removeAll { ($0["id"] as? String) == categoryID }
            categories.append([
                "id": categoryID,
                "localizedNameKey": "LiveDesk",
                "localizedDescriptionKey": "Live wallpapers from LiveDesk",
                "previewImage": thumbURLString,
                "representativeAssetID": newID,
                "preferredOrder": 99,
                "subcategories": [[
                    "id": subcategoryID,
                    "localizedNameKey": "LiveDesk",
                    "localizedDescriptionKey": "Live wallpapers from LiveDesk",
                    "previewImage": thumbURLString,
                    "representativeAssetID": newID,
                    "preferredOrder": 0
                ]]
            ])

            // Drop the previous LiveDesk asset(s) — anything in our subcategory.
            assets.removeAll { ($0["subcategories"] as? [String])?.contains(subcategoryID) == true }
            assets.append([
                "id": newID,
                "shotID": "CUSTOM_LIVEDESK",
                "localizedNameKey": "LiveDesk Live Wallpaper",
                "accessibilityLabel": "LiveDesk Live Wallpaper",
                "previewImage": thumbURLString,
                "url-4K-SDR-240FPS": videoURLString,
                "categories": [categoryID],
                "subcategories": [subcategoryID],
                "includeInShuffle": true,
                "showInTopLevel": true,
                "preferredOrder": 0,
                "pointsOfInterest": ["0": "CUSTOM_LIVEDESK_0"]
            ])

            json["categories"] = categories
            json["assets"] = assets

            let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            _ = try JSONSerialization.jsonObject(with: newData) // validate before committing
            try newData.write(to: manifestURL, options: .atomic)

            // Point future writes at the new id and delete the old media files.
            currentAssetID = newID
            if let oldID, oldID != newID {
                try? fm.removeItem(at: videoFile(for: oldID))
                try? fm.removeItem(at: thumbFile(for: oldID))
            }

            restartWallpaperAgent()
        } catch {
            try? fm.removeItem(at: newVideo)
            try? fm.removeItem(at: newThumb)
            if let registrarError = error as? RegistrarError { throw registrarError }
            throw RegistrarError.ioError(error)
        }
    }

    /// Restore the user's prior wallpaper only if LiveDesk is still the active Aerial.
    /// Never overwrite a newer wallpaper chosen in System Settings.
    nonisolated static func restorePreviousWallpaper() throws {
        let fm = FileManager.default
        let indexBackup = indexURL.deletingLastPathComponent()
            .appendingPathComponent("Index.plist.livedesk-backup")
        if let id = currentAssetID,
           let index = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: indexURL), options: [], format: nil) as? [String: Any],
           activeAssetID(in: index) == id {
            guard fm.fileExists(atPath: indexBackup.path) else {
                throw RegistrarError.backupMissing
            }
            let original = try Data(contentsOf: indexBackup)
            try original.write(to: indexURL, options: .atomic)
        }

        if fm.fileExists(atPath: manifestURL.path),
           var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] {
            var categories = json["categories"] as? [[String: Any]] ?? []
            var assets = json["assets"] as? [[String: Any]] ?? []
            categories.removeAll { ($0["id"] as? String) == categoryID }
            assets.removeAll { ($0["subcategories"] as? [String])?.contains(subcategoryID) == true }
            json["categories"] = categories
            json["assets"] = assets
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
                .write(to: manifestURL, options: .atomic)
        }
        if let id = currentAssetID {
            try? fm.removeItem(at: videoFile(for: id))
            try? fm.removeItem(at: thumbFile(for: id))
        }
        currentAssetID = nil
        try? fm.removeItem(at: indexBackup)
        restartWallpaperAgent()
    }

    nonisolated private static func activeAssetID(in index: [String: Any]) -> String? {
        guard let container = index["AllSpacesAndDisplays"] as? [String: Any],
              let linked = container["Linked"] as? [String: Any],
              let content = linked["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [[String: Any]])?.first,
              let configuration = choice["Configuration"] as? Data,
              let value = try? PropertyListSerialization.propertyList(
                from: configuration, options: [], format: nil) as? [String: Any]
        else { return nil }
        return value["assetID"] as? String
    }

    // MARK: - One-click install: register + set as live desktop + lock wallpaper

    /// The full flow: register the video as an Aerial AND set it as the active
    /// wallpaper using the "linked" structure macOS itself writes for its dynamic
    /// wallpapers — which is what makes the video play LIVE ON THE LOCK SCREEN,
    /// not just as an idle screen saver. Reverse-engineered by diffing the store
    /// before/after selecting an Apple dynamic wallpaper.
    nonisolated static func installAsScreensaver(videoURL: URL) async throws {
        try await register(videoURL: videoURL)
        do {
            try setAsActiveLiveWallpaper()
        } catch {
            try? restorePreviousWallpaper()
            throw error
        }
    }

    /// Writes the "linked" wallpaper structure (Type = "linked" in
    /// AllSpacesAndDisplays + SystemDefault) pointing at LiveDesk's Aerial asset.
    /// This is the exact shape macOS produces when you pick a Dynamic wallpaper,
    /// and it plays on the desktop AND the lock screen. Written while
    /// WallpaperAgent is stopped so it can't clobber the edit on exit.
    nonisolated static func setAsActiveLiveWallpaper() throws {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw RegistrarError.manifestNotFound
        }
        guard let assetID = currentAssetID else { throw RegistrarError.manifestNotFound }

        // One-time backup of the untouched store.
        let backupURL = indexURL.deletingLastPathComponent()
            .appendingPathComponent("Index.plist.livedesk-backup")
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.copyItem(at: indexURL, to: backupURL)
        }

        stop("WallpaperAgent")
        Thread.sleep(forTimeInterval: 1.0)

        do {
            let data = try Data(contentsOf: indexURL)
            guard var plist = try PropertyListSerialization.propertyList(
                    from: data, options: [.mutableContainersAndLeaves], format: nil) as? [String: Any] else {
                throw RegistrarError.manifestNotFound
            }

            // Aerial Configuration = nested binary plist of {assetID: …}.
            let config = try PropertyListSerialization.data(
                fromPropertyList: ["assetID": assetID], format: .binary, options: 0)

            // Reuse an EncodedOptionValues blob already in the store (keeps the
            // exact styling macOS expects); fall back to a minimal FillScreen one.
            let options = try (firstEncodedOptionValues(in: plist) ?? minimalOptionValues())

            let choice: [String: Any] = [
                "Provider": "com.apple.wallpaper.choice.aerials",
                "Files": [],
                "Configuration": config
            ]
            let content: [String: Any] = [
                "Choices": [choice],
                "Shuffle": "$null",
                "EncodedOptionValues": options
            ]
            let linked: [String: Any] = [
                "LastSet": Date(),
                "LastUse": Date(),
                "Content": content
            ]
            let container: [String: Any] = ["Type": "linked", "Linked": linked]

            // Apply the linked wallpaper globally and clear per-display / per-Space
            // overrides, exactly as macOS does for an "all Spaces" dynamic wallpaper.
            plist["AllSpacesAndDisplays"] = container
            plist["SystemDefault"] = container
            plist["Displays"] = [String: Any]()
            plist["Spaces"] = [String: Any]()

            let out = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .binary, options: 0)
            try out.write(to: indexURL, options: .atomic)
        } catch let e as RegistrarError {
            throw e
        } catch {
            throw RegistrarError.ioError(error)
        }

        stop("WallpaperAgent")
        stop("WallpaperAerialsExtension")
    }

    /// Finds the first EncodedOptionValues Data anywhere in the store, to reuse
    /// macOS's own option styling instead of guessing it.
    nonisolated private static func firstEncodedOptionValues(in obj: Any) -> Data? {
        if let dict = obj as? [String: Any] {
            if let d = dict["EncodedOptionValues"] as? Data { return d }
            for v in dict.values { if let f = firstEncodedOptionValues(in: v) { return f } }
        } else if let arr = obj as? [Any] {
            for v in arr { if let f = firstEncodedOptionValues(in: v) { return f } }
        }
        return nil
    }

    /// Minimal options: fill the screen. Used only if the store had none.
    nonisolated private static func minimalOptionValues() throws -> Data {
        let values: [String: Any] = ["values": ["placement": ["picker": ["_0": ["id": "FillScreen"]]]]]
        return try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    nonisolated private static func stop(_ processName: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = [processName]
        try? task.run()
        task.waitUntilExit()
    }

    nonisolated private static func restartWallpaperAgent() {
        stop("WallpaperAgent")
        stop("WallpaperAerialsExtension")
    }

    /// Kick the wallpaper agent to re-render. Used on lock: macOS otherwise caches
    /// a static frame after the first play, so a fresh render makes the video play
    /// again on subsequent locks. Only nudges when our live wallpaper is active.
    nonisolated static func nudgeRerenderIfActive() {
        guard let id = currentAssetID,
              let data = try? Data(contentsOf: indexURL),
              let index = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              activeAssetID(in: index) == id else { return }
        stop("WallpaperAgent")
    }
}
