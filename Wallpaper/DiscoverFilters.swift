import CoreGraphics
import Foundation

struct DiscoverFilters: Equatable {
    enum Shape: String, CaseIterable {
        case any = "Any shape", landscape = "Landscape", portrait = "Portrait", square = "Square"

        func matches(_ dimensions: CGSize) -> Bool {
            switch self {
            case .any: true
            case .landscape: dimensions.width > dimensions.height
            case .portrait: dimensions.width < dimensions.height
            case .square: dimensions.width == dimensions.height
            }
        }
    }

    enum Resolution: String, CaseIterable {
        case any = "Any resolution", belowHD = "Below 1080p", hd = "1080p", qhd = "1440p", uhd = "2160p and up"

        func matches(_ dimensions: CGSize) -> Bool {
            let shortEdge = min(dimensions.width, dimensions.height)
            switch self {
            case .any: return true
            case .belowHD: return shortEdge < 1080
            case .hd: return shortEdge >= 1080 && shortEdge < 1440
            case .qhd: return shortEdge >= 1440 && shortEdge < 2160
            case .uhd: return shortEdge >= 2160
            }
        }
    }

    enum FileSize: String, CaseIterable {
        case any = "Any file size", small = "Under 10 MB", medium = "10–25 MB", large = "Over 25 MB"

        func matches(_ bytes: Int64) -> Bool {
            switch self {
            case .any: true
            case .small: bytes < 10_000_000
            case .medium: (10_000_000...25_000_000).contains(bytes)
            case .large: bytes > 25_000_000
            }
        }
    }

    var shape: Shape = .any
    var resolution: Resolution = .any
    var fileSize: FileSize = .any

    var activeCount: Int {
        [shape != .any, resolution != .any, fileSize != .any].filter { $0 }.count
    }

    func canEvaluate(_ metadata: CommunityMediaMetadata) -> Bool {
        ((shape == .any && resolution == .any) || metadata.dimensions != nil) &&
            (fileSize == .any || metadata.bytes != nil)
    }

    func matches(_ metadata: CommunityMediaMetadata) -> Bool {
        guard canEvaluate(metadata) else { return false }
        if let dimensions = metadata.dimensions, !shape.matches(dimensions) || !resolution.matches(dimensions) {
            return false
        }
        return metadata.bytes.map(fileSize.matches) ?? true
    }
}

struct CommunityMediaMetadata: Sendable {
    let dimensions: CGSize?
    let bytes: Int64?
}
