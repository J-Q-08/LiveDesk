import Foundation
import Security
import Combine

struct CommunitySession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userID: String
    let email: String
}

@MainActor final class CommunityAuth: ObservableObject {
    static let shared = CommunityAuth()
    @Published private(set) var session: CommunitySession?
    private let keychainService = "LiveDesk.CommunityAuth"

    private init() {
        guard let data = readKeychain() else { return }
        session = try? JSONDecoder().decode(CommunitySession.self, from: data)
    }

    func signIn(email: String, password: String) async throws {
        let response = try await authRequest(path: "auth/v1/token?grant_type=password",
                                             body: ["email": email, "password": password])
        try save(response)
    }

    func signUp(email: String, password: String) async throws -> Bool {
        let response = try await authRequest(path: "auth/v1/signup",
                                             body: ["email": email, "password": password])
        if response.accessToken != nil {
            try save(response)
            return true
        }
        return false
    }

    func validSession() async throws -> CommunitySession {
        guard let current = session else { throw AuthError.signInRequired }
        if current.expiresAt > Date().addingTimeInterval(60) { return current }
        let response = try await authRequest(path: "auth/v1/token?grant_type=refresh_token",
                                             body: ["refresh_token": current.refreshToken])
        try save(response)
        guard let session else { throw AuthError.signInRequired }
        return session
    }

    func signOut() {
        session = nil
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService]
        SecItemDelete(query as CFDictionary)
    }

    private func authRequest(path: String, body: [String: String]) async throws -> AuthResponse {
        // URLComponents keeps the grant_type query separate from the path.
        guard let url = URL(string: path, relativeTo: CommunityService.projectURL) else {
            throw AuthError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(CommunityService.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try CommunityService.check(response, data: data)
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    private func save(_ response: AuthResponse) throws {
        guard let accessToken = response.accessToken,
              let refreshToken = response.refreshToken,
              let user = response.user else { throw AuthError.invalidResponse }
        let next = CommunitySession(accessToken: accessToken, refreshToken: refreshToken,
                                    expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600)),
                                    userID: user.id, email: user.email ?? "")
        let data = try JSONEncoder().encode(next)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw AuthError.keychain
        }
        session = next
    }

    private func readKeychain() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private struct AuthResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?
        let user: User?
        struct User: Decodable {
            let id: String
            let email: String?
        }
        enum CodingKeys: String, CodingKey {
            case user
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private enum AuthError: LocalizedError {
        case signInRequired, invalidResponse, keychain
        var errorDescription: String? {
            switch self {
            case .signInRequired: "Sign in to publish a video."
            case .invalidResponse: "The sign-in service returned an invalid response."
            case .keychain: "Couldn’t securely save your sign-in on this Mac."
            }
        }
    }
}
