import Foundation
import AVFoundation

struct LibraryVideo: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let filename: String
    let communityID: String?

    nonisolated init(id: UUID, name: String, filename: String, communityID: String? = nil) {
        self.id = id
        self.name = name
        self.filename = filename
        self.communityID = communityID
    }
}

enum VideoLibrary {
    nonisolated static let maxUploadBytes = 52_428_800
    nonisolated private static let indexLock = NSLock()

    nonisolated private static func validateFileSize(_ file: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber else { throw ImportError.unreadableFile }
        guard bytes.int64Value > 0 else { throw ImportError.emptyFile }
        guard bytes.int64Value <= maxUploadBytes else { throw ImportError.tooLarge }
    }

    nonisolated static func validatePlayableVideo(_ file: URL) async throws {
        do {
            _ = try await VideoPlayback.inspect(AVURLAsset(url: file))
        } catch {
            try Task.checkCancellation()
            throw ImportError.unplayableVideo
        }
    }

    private enum ImportError: LocalizedError {
        case unsupportedFormat, unreadableFile, emptyFile, tooLarge, unplayableVideo

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "Choose an MP4, MOV, or M4V video."
            case .unreadableFile: "Couldn’t read the selected video."
            case .emptyFile: "The selected video is empty."
            case .tooLarge: "This video exceeds the 50 MB community upload limit."
            case .unplayableVideo: "This file isn’t a playable video. It may be damaged or use an unsupported codec."
            }
        }
    }

    nonisolated private static var directory: URL {
        get throws {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("LiveDesk/Videos", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    nonisolated private static var indexURL: URL {
        get throws { try directory.appendingPathComponent("library.json") }
    }

    nonisolated static func load() throws -> [LibraryVideo] {
        try indexLock.withLock { try loadUnlocked() }
    }

    nonisolated private static func loadUnlocked() throws -> [LibraryVideo] {
        let index = try indexURL
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        return try JSONDecoder().decode([LibraryVideo].self, from: Data(contentsOf: index))
    }

    nonisolated static func url(for video: LibraryVideo) throws -> URL {
        let file = try directory.appendingPathComponent(video.filename)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return file
    }

    nonisolated static func importVideo(from source: URL, extension fileExtension: String,
                                       title: String,
                                       communityID: String? = nil) async throws -> LibraryVideo {
        let fileExtension = fileExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(fileExtension) else { throw ImportError.unsupportedFormat }
        let id = UUID()
        let filename = id.uuidString + "." + fileExtension
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            let hasScopedAccess = source.startAccessingSecurityScopedResource()
            defer { if hasScopedAccess { source.stopAccessingSecurityScopedResource() } }
            try validateFileSize(source)
            try FileManager.default.copyItem(at: source, to: staged)
        }
        try validateFileSize(staged)
        try await validatePlayableVideo(staged)
        try Task.checkCancellation()
        let destination = try directory.appendingPathComponent(filename)
        return try indexLock.withLock {
            var items = try loadUnlocked()
            if let communityID {
                if let existing = items.first(where: { $0.communityID == communityID && (try? url(for: $0)) != nil }) {
                    return existing
                }
                items.removeAll { $0.communityID == communityID }
            }
            let video = LibraryVideo(id: id, name: title, filename: filename, communityID: communityID)
            try FileManager.default.moveItem(at: staged, to: destination)
            do {
                let data = try JSONEncoder().encode(items + [video])
                try data.write(to: indexURL, options: .atomic)
                return video
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    nonisolated static func markPublished(_ video: LibraryVideo, communityID: String) throws -> [LibraryVideo] {
        try indexLock.withLock {
            let updated = try loadUnlocked().map { item in
                item.id == video.id
                    ? LibraryVideo(id: item.id, name: item.name, filename: item.filename,
                                   communityID: communityID)
                    : item
            }
            try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
            return updated
        }
    }

    nonisolated static func rename(_ video: LibraryVideo, to name: String) throws -> [LibraryVideo] {
        try indexLock.withLock {
            var items = try loadUnlocked()
            guard let index = items.firstIndex(where: { $0.id == video.id }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let current = items[index]
            items[index] = LibraryVideo(id: current.id, name: name, filename: current.filename,
                                        communityID: current.communityID)
            try JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
            return items
        }
    }

    nonisolated static func remove(_ video: LibraryVideo) throws -> [LibraryVideo] {
        try indexLock.withLock {
            let remaining = try loadUnlocked().filter { $0.id != video.id }
            let original = try directory.appendingPathComponent(video.filename)
            let staged = try directory.appendingPathComponent(".deleting-\(video.filename)")
            try FileManager.default.moveItem(at: original, to: staged)
            do {
                try JSONEncoder().encode(remaining).write(to: indexURL, options: .atomic)
            } catch {
                try? FileManager.default.moveItem(at: staged, to: original)
                throw error
            }
            try? FileManager.default.removeItem(at: staged)
            return remaining
        }
    }
}

