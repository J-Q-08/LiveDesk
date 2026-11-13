// Adapted from CaveWall (MIT License, copyright 2026 Rishav Bairagya).
// See THIRD_PARTY_NOTICES.md for license and source.
// The temporal HEVC compression setup is adapted from macos-custom-video-wallpaper-fix (MIT License, copyright 2026 AlexisBCD).
// See THIRD_PARTY_NOTICES.md for license and source.
import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import VideoToolbox

private final class AerialWriterPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let transform: CGAffineTransform
    nonisolated(unsafe) private var writer: AVAssetWriter?
    nonisolated(unsafe) private var input: AVAssetWriterInput?
    nonisolated(unsafe) private var failure: String?

    nonisolated init(destination: URL, transform: CGAffineTransform) {
        self.destination = destination
        self.transform = transform
    }

    nonisolated func append(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        lock.lock()
        defer { lock.unlock() }

        guard failure == nil else { return }
        guard status == noErr else {
            failure = "VideoToolbox did not return an encoded video frame (\(status))."
            return
        }
        guard let sampleBuffer else { return }
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            failure = "VideoToolbox returned a frame without a video format."
            return
        }

        if writer == nil {
            do {
                let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                input.expectsMediaDataInRealTime = false
                input.transform = transform
                guard writer.canAdd(input) else {
                    failure = "The Lock Screen video writer rejected the encoded video track."
                    return
                }
                writer.add(input)
                guard writer.startWriting() else {
                    failure = writer.error?.localizedDescription ?? "The Lock Screen video writer could not start."
                    return
                }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                self.writer = writer
                self.input = input
            } catch {
                failure = error.localizedDescription
                return
            }
        }

        guard let writer, let input else { return }
        while !input.isReadyForMoreMediaData && writer.status == .writing {
            usleep(500)
        }
        guard writer.status == .writing, input.append(sampleBuffer) else {
            failure = writer.error?.localizedDescription ?? "The Lock Screen video could not be written."
            writer.cancelWriting()
            return
        }
    }

    nonisolated func finish() throws {
        lock.lock()
        if let failure {
            lock.unlock()
            throw LiveDeskAerialRegistrar.RegistrarError.transcodeFailed(failure)
        }
        guard let writer, let input else {
            lock.unlock()
            throw LiveDeskAerialRegistrar.RegistrarError.transcodeFailed("the encoder produced no frames")
        }
        input.markAsFinished()
        lock.unlock()

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw LiveDeskAerialRegistrar.RegistrarError.transcodeFailed(
                writer.error?.localizedDescription ?? "the encoded video could not be finalized")
        }
    }
}

/// Registers videos in the private per-user Aerial catalog used by macOS Wallpaper.
enum LiveDeskAerialRegistrar {
    nonisolated private static let subcategoryID = "1DA60D58-7B3F-4A52-A441-879D57DD0002"
    nonisolated private static let encodingVersion = 3
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

    /// Writes video-only Main10 HEVC with temporal sublayers required by the Aerial lock transition.
    nonisolated private static func transcodeToHEVC(source: URL, destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RegistrarError.transcodeFailed("no video track in that file")
        }

        let (t, naturalSize, nominalFrameRate) = try await track.load(
            .preferredTransform, .naturalSize, .nominalFrameRate)
        let srcW = abs(naturalSize.width), srcH = abs(naturalSize.height)
        guard srcW.isFinite, srcH.isFinite, srcW > 0, srcH > 0 else {
            throw RegistrarError.transcodeFailed("invalid video dimensions")
        }
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
        guard reader.startReading() else {
            throw RegistrarError.transcodeFailed(reader.error?.localizedDescription ?? "the video reader could not start")
        }
        guard let firstSample = readerOutput.copyNextSampleBuffer(),
              let firstPixelBuffer = CMSampleBufferGetImageBuffer(firstSample) else {
            throw RegistrarError.transcodeFailed(reader.error?.localizedDescription ?? "the video contains no readable frames")
        }
        let sourceWidth = CVPixelBufferGetWidth(firstPixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(firstPixelBuffer)
        let scale = min(1.0, 1920.0 / Double(max(sourceWidth, sourceHeight)))
        let outputWidth = max(2, Int((Double(sourceWidth) * scale / 2).rounded()) * 2)
        let outputHeight = max(2, Int((Double(sourceHeight) * scale / 2).rounded()) * 2)
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey: outputWidth,
            kCVPixelBufferHeightKey: outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 3]
        var pixelBufferPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pixelBufferPool
        )
        guard poolStatus == kCVReturnSuccess, let pixelBufferPool else {
            throw RegistrarError.transcodeFailed("could not allocate a 10-bit video buffer (\(poolStatus))")
        }
        let imageContext = CIContext(options: [.useSoftwareRenderer: false])

        func preparePixelBuffer(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = CVPixelBufferGetWidth(source)
            let height = CVPixelBufferGetHeight(source)
            guard width != outputWidth || height != outputHeight else { return source }
            var destination: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &destination)
            guard status == kCVReturnSuccess, let destination else {
                throw RegistrarError.transcodeFailed("could not resize a video frame (\(status))")
            }
            let image = CIImage(cvPixelBuffer: source).transformed(by: CGAffineTransform(
                scaleX: CGFloat(outputWidth) / CGFloat(width),
                y: CGFloat(outputHeight) / CGFloat(height)
            ))
            imageContext.render(image, to: destination,
                                bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
                                colorSpace: nil)
            return destination
        }

        let pipeline = AerialWriterPipeline(destination: destination, transform: t)
        let outputCallback: VTCompressionOutputCallback = { callbackContext, _, status, _, sampleBuffer in
            guard let callbackContext else { return }
            let pipeline = Unmanaged<AerialWriterPipeline>.fromOpaque(callbackContext).takeUnretainedValue()
            pipeline.append(status: status, sampleBuffer: sampleBuffer)
        }
        var compressionSession: VTCompressionSession?
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(outputWidth),
            height: Int32(outputHeight),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: outputCallback,
            refcon: Unmanaged.passUnretained(pipeline).toOpaque(),
            compressionSessionOut: &compressionSession
        )
        guard createStatus == noErr, let session = compressionSession else {
            throw RegistrarError.transcodeFailed("VideoToolbox could not create a hardware HEVC encoder (\(createStatus)).")
        }
        defer { VTCompressionSessionInvalidate(session) }

        func setEncoderProperty(_ key: CFString, value: CFTypeRef) throws {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                throw RegistrarError.transcodeFailed("VideoToolbox rejected a required Lock Screen encoding setting (\(status)).")
            }
        }
        try setEncoderProperty(kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        try setEncoderProperty(kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        try setEncoderProperty(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
        try setEncoderProperty(kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        try setEncoderProperty(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 5))
        try setEncoderProperty(kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 12_000_000))
        try setEncoderProperty(kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        try setEncoderProperty(kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        try setEncoderProperty(kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        try setEncoderProperty(kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        try setEncoderProperty(kVTCompressionPropertyKey_BaseLayerFrameRate, value: NSNumber(value: Double(fps) / 2.0))

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            throw RegistrarError.transcodeFailed("VideoToolbox could not prepare the temporal video encoder (\(prepareStatus)).")
        }

        func encode(_ sample: CMSampleBuffer) throws {
            guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw RegistrarError.transcodeFailed("the video contains an unreadable frame")
            }
            let pixelBuffer = try preparePixelBuffer(sourcePixelBuffer)
            var duration = CMSampleBufferGetDuration(sample)
            if !duration.isValid || duration.value == 0 {
                duration = CMTime(value: 1, timescale: Int32(fps))
            }
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                duration: duration,
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            guard status == noErr else {
                throw RegistrarError.transcodeFailed("VideoToolbox could not encode a Lock Screen frame (\(status)).")
            }
        }
        try encode(firstSample)
        while let sample = readerOutput.copyNextSampleBuffer() {
            try encode(sample)
        }
        guard reader.status == .completed else {
            throw RegistrarError.transcodeFailed(reader.error?.localizedDescription ?? "the video reader stopped before the end")
        }
        let finishStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard finishStatus == noErr else {
            throw RegistrarError.transcodeFailed("VideoToolbox could not finish the Lock Screen video (\(finishStatus)).")
        }
        try pipeline.finish()
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
                  asset["liveDeskAerialEncodingVersion"] as? Int == encodingVersion,
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
                "liveDeskAerialEncodingVersion": encodingVersion,
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
