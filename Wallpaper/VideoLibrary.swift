import Foundation

struct LibraryVideo: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let filename: String
}

enum VideoLibrary {
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
        let hasScopedAccess = source.startAccessingSecurityScopedResource()
        defer { if hasScopedAccess { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let filename = id.uuidString + "." + source.pathExtension.lowercased()
        let destination = try directory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            let video = LibraryVideo(id: id, name: source.deletingPathExtension().lastPathComponent,
                                     filename: filename)
            let data = try JSONEncoder().encode(existing + [video])
            try data.write(to: indexURL, options: .atomic)
            return video
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
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

