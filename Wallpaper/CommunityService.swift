import Foundation
import AVFoundation
import AppKit

struct CommunityWallpaper: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let createdAt: String
    let videoPath: String
    let thumbnailPath: String?
    let fileExtension: String

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case videoPath = "video_path"
        case thumbnailPath = "thumbnail_path"
        case fileExtension = "file_extension"
    }
}

enum CommunityService {
    static let projectURL = URL(string: "https://tbhegscgjjaiiwoqooak.supabase.co")!
    static let publishableKey = "sb_publishable_Mza44-XuiiHkBkaVIOqWPg_GgZWfJTe"
    private static let bucket = "wallpapers"

    static func mediaURL(path: String?) -> URL? {
        guard let path else { return nil }
        return projectURL.appending(path: "storage/v1/object/public/\(bucket)/\(path)")
    }

    static func list(query: String = "", offset: Int = 0, ownerID: String? = nil,
                     limit: Int = 50) async throws -> [CommunityWallpaper] {
        var components = URLComponents(url: projectURL.appending(path: "rest/v1/wallpapers"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "select", value: "id,title,created_at,video_path,thumbnail_path,file_extension"),
            .init(name: "order", value: "created_at.desc,id.desc"),
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset))
        ]
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty { components.queryItems?.append(.init(name: "title", value: "ilike.*\(term)*")) }
        if let ownerID { components.queryItems?.append(.init(name: "owner_id", value: "eq.\(ownerID)")) }
        var request = URLRequest(url: components.url!)
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        return try JSONDecoder().decode([CommunityWallpaper].self, from: data)
    }

    static func checkConnection() async throws {
        _ = try await list(limit: 1)
    }

    static func publish(video: LibraryVideo, source: URL, session: CommunitySession) async throws -> CommunityWallpaper {
        let fileExtension = source.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(fileExtension) else { throw CommunityError.unsupportedVideo }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= 52_428_800 else { throw CommunityError.tooLarge }
        let id = UUID().uuidString.lowercased()
        let path = "\(session.userID)/\(id).\(fileExtension)"
        try await upload(source, path: path, mimeType: fileExtension == "mov" ? "video/quicktime" : "video/mp4", token: session.accessToken)
        var thumbnailPath: String?
        if let thumbnail = try? await thumbnail(for: source) {
            let candidate = "\(session.userID)/\(id).png"
            if (try? await upload(thumbnail, path: candidate, mimeType: "image/png", token: session.accessToken)) != nil {
                thumbnailPath = candidate
            }
        }
        var request = URLRequest(url: projectURL.appending(path: "rest/v1/wallpapers"))
        request.httpMethod = "POST"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": id, "owner_id": session.userID, "title": String(video.name.prefix(100)),
            "video_path": path, "thumbnail_path": thumbnailPath as Any? ?? NSNull(), "file_extension": fileExtension
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data: data)
        guard let published = try JSONDecoder().decode([CommunityWallpaper].self, from: data).first else {
            throw CommunityError.invalidResponse
        }
        return published
    }

    static func download(wallpaper: CommunityWallpaper, existing: [LibraryVideo]) async throws -> LibraryVideo {
        guard ["mp4", "mov", "m4v"].contains(wallpaper.fileExtension.lowercased()),
              let url = mediaURL(path: wallpaper.videoPath) else { throw CommunityError.unsupportedVideo }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        try check(response)
        return try await Task.detached(priority: .userInitiated) {
            try VideoLibrary.importVideo(from: temporary, extension: wallpaper.fileExtension,
                                         title: wallpaper.title, existing: existing, communityID: wallpaper.id)
        }.value
    }

    private static func upload(_ file: URL, path: String, mimeType: String, token: String) async throws {
        let request = uploadRequest(path: path, mimeType: mimeType, token: token)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        try check(response, data: data)
    }

    private static func upload(_ data: Data, path: String, mimeType: String, token: String) async throws {
        var request = uploadRequest(path: path, mimeType: mimeType, token: token)
        request.httpBody = data
        let (result, response) = try await URLSession.shared.data(for: request)
        try check(response, data: result)
    }

    private static func uploadRequest(path: String, mimeType: String, token: String) -> URLRequest {
        var request = URLRequest(url: projectURL.appending(path: "storage/v1/object/\(bucket)/\(path)"))
        request.httpMethod = "POST"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        return request
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

    static func check(_ response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw CommunityError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let details = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (details?["msg"] as? String)
                ?? (details?["message"] as? String)
                ?? (details?["error_description"] as? String)
                ?? "Please try again."
            throw CommunityError.server(http.statusCode, message)
        }
    }

    private enum CommunityError: LocalizedError {
        case invalidResponse, unsupportedVideo, tooLarge, server(Int, String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The community service returned an invalid response."
            case .unsupportedVideo: "Choose an MP4, MOV, or M4V video."
            case .tooLarge: "The community upload limit is 50 MB."
            case .server(let code, let detail): "Community service error \(code): \(detail)"
            }
        }
    }
}
