import Foundation

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

    nonisolated static func validateForUpload(_ source: URL) throws {
        guard ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) else {
            throw UploadError.unsupportedFormat
        }
        let hasScopedAccess = source.startAccessingSecurityScopedResource()
        defer { if hasScopedAccess { source.stopAccessingSecurityScopedResource() } }
        let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        guard let size else { throw UploadError.unreadableFile }
        guard size.intValue > 0 else { throw UploadError.emptyFile }
        guard size.intValue <= maxUploadBytes else { throw UploadError.tooLarge }
    }

    private enum UploadError: LocalizedError {
        case unsupportedFormat, unreadableFile, emptyFile, tooLarge

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "Choose an MP4, MOV, or M4V video."
            case .unreadableFile: "Couldn’t read the selected video."
            case .emptyFile: "The selected video is empty."
            case .tooLarge: "This video exceeds the 50 MB community upload limit."
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

    nonisolated static func importVideo(from source: URL, existing: [LibraryVideo]) throws -> LibraryVideo {
        try importVideo(from: source, extension: source.pathExtension,
                        title: source.deletingPathExtension().lastPathComponent, existing: existing)
    }

    nonisolated static func importVideo(from source: URL, extension fileExtension: String,
                                       title: String, existing: [LibraryVideo],
                                       communityID: String? = nil) throws -> LibraryVideo {
        let hasScopedAccess = source.startAccessingSecurityScopedResource()
        defer { if hasScopedAccess { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let filename = id.uuidString + "." + fileExtension.lowercased()
        let destination = try directory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            let video = LibraryVideo(id: id, name: title, filename: filename,
                                     communityID: communityID)
            let data = try JSONEncoder().encode(existing + [video])
            try data.write(to: indexURL, options: .atomic)
            return video
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    nonisolated static func markPublished(_ video: LibraryVideo, communityID: String,
                                          existing: [LibraryVideo]) throws -> [LibraryVideo] {
        let updated = existing.map { item in
            item.id == video.id
                ? LibraryVideo(id: item.id, name: item.name, filename: item.filename,
                               communityID: communityID)
                : item
        }
        try JSONEncoder().encode(updated).write(to: indexURL, options: .atomic)
        return updated
    }

    nonisolated static func remove(_ video: LibraryVideo, existing: [LibraryVideo]) throws {
        let remaining = existing.filter { $0.id != video.id }
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
    }
}

