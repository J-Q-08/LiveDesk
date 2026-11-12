import Foundation
import AVFoundation
import AppKit

struct CommunityWallpaper: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let createdAt: String
    let videoPath: String
    let thumbnailPath: String
    let fileExtension: String
}

enum CommunityService {
    static func baseURL(_ address: String) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host,
              url.scheme == "https" ||
                (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw CommunityError.invalidServer
        }
        return url
    }

    static func list(server: String, query: String = "", offset: Int = 0) async throws -> [CommunityWallpaper] {
        var components = URLComponents(url: try baseURL(server).appending(path: "api/wallpapers"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "offset", value: String(offset)),
                                 URLQueryItem(name: "limit", value: "50")]
        if !query.isEmpty { components.queryItems?.append(URLQueryItem(name: "q", value: query)) }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try check(response)
        return try JSONDecoder().decode([CommunityWallpaper].self, from: data)
    }

    static func publish(server: String, video: LibraryVideo, source: URL) async throws -> CommunityWallpaper {
        var components = URLComponents(url: try baseURL(server).appending(path: "api/wallpapers"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "title", value: video.name)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(source.pathExtension.lowercased(), forHTTPHeaderField: "X-Wallpaper-Extension")
        request.setValue(video.id.uuidString, forHTTPHeaderField: "X-Wallpaper-ID")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: source)
        try check(response)
        let published = try JSONDecoder().decode(CommunityWallpaper.self, from: data)

        // A failed thumbnail should not turn a successful publication into a retry and duplicate post.
        if let image = try? await thumbnail(for: source) {
            var thumbnailRequest = URLRequest(url: try baseURL(server).appending(path: published.thumbnailPath))
            thumbnailRequest.httpMethod = "PUT"
            thumbnailRequest.setValue("image/png", forHTTPHeaderField: "Content-Type")
            _ = try? await URLSession.shared.upload(for: thumbnailRequest, from: image)
        }
        return published
    }

    static func download(server: String, wallpaper: CommunityWallpaper,
                         existing: [LibraryVideo]) async throws -> LibraryVideo {
        guard ["mp4", "mov", "m4v"].contains(wallpaper.fileExtension.lowercased()) else {
            throw CommunityError.unsupportedVideo
        }
        let url = try baseURL(server).appending(path: wallpaper.videoPath)
        let (temporary, response) = try await URLSession.shared.download(from: url)
        try check(response)
        return try await Task.detached(priority: .userInitiated) {
            try VideoLibrary.importVideo(from: temporary, extension: wallpaper.fileExtension,
                                         title: wallpaper.title, existing: existing,
                                         communityID: wallpaper.id)
        }.value
    }

    private static func thumbnail(for source: URL) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        let frame = try await generator.image(at: .zero).image
        guard let data = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CommunityError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw CommunityError.server(http.statusCode)
        }
    }

    private enum CommunityError: LocalizedError {
        case invalidServer, invalidResponse, unsupportedVideo, server(Int)

        var errorDescription: String? {
            switch self {
            case .invalidServer: "Use an HTTPS server address, or HTTP on this Mac."
            case .invalidResponse: "The community server returned an invalid response."
            case .unsupportedVideo: "This shared video has an unsupported file type."
            case .server(let code): "The community server returned error \(code)."
            }
        }
    }
}
