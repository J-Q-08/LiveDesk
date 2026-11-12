import SwiftUI
import AVFoundation
import AppKit

enum VideoLayout: String, CaseIterable, Identifiable {
    case fit = "Fit"
    case fill = "Fill"
    case stretch = "Stretch"
    case center = "Center"
    case tile = "Tile"

    var id: String { rawValue }
}

struct VideoCanvas: NSViewRepresentable {
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

final class VideoCanvasView: NSView {
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

