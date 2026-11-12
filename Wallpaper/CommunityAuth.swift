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
    @Published private(set) var restoreError: String?
    @Published private(set) var isRestoring = true
    private var restoreGeneration = 0

    private init() {
        let generation = restoreGeneration
        Task { [weak self] in
            let (data, status) = await KeychainStore.shared.read()
            let restored = data.flatMap { try? JSONDecoder().decode(CommunitySession.self, from: $0) }
            guard let self, self.restoreGeneration == generation, self.session == nil else { return }
            self.session = restored
            if status != errSecSuccess && status != errSecItemNotFound {
                self.restoreError = "Couldn’t restore your saved sign-in (Keychain error \(status)). Sign in again."
            } else if data != nil && restored == nil {
                self.restoreError = "Your saved sign-in couldn’t be read. Sign in again."
            }
            self.isRestoring = false
        }
    }

    func signIn(email: String, password: String) async throws {
        let generation = restoreGeneration
        let response = try await authRequest(path: "auth/v1/token?grant_type=password",
                                             body: ["email": email, "password": password])
        try await save(response, expectedGeneration: generation)
    }

    func signUp(email: String, password: String) async throws -> Bool {
        let generation = restoreGeneration
        let response = try await authRequest(path: "auth/v1/signup",
                                             body: ["email": email, "password": password])
        guard response.user != nil else { throw AuthError.invalidResponse }
        if response.accessToken != nil {
            try await save(response, expectedGeneration: generation)
            return true
        }
        return false
    }

    func validSession() async throws -> CommunitySession {
        guard let current = session else { throw AuthError.signInRequired }
        if current.expiresAt > Date().addingTimeInterval(60) { return current }
        let generation = restoreGeneration
        let response = try await authRequest(path: "auth/v1/token?grant_type=refresh_token",
                                             body: ["refresh_token": current.refreshToken])
        guard session?.refreshToken == current.refreshToken else { throw AuthError.sessionChanged }
        try await save(response, expectedGeneration: generation)
        guard let session else { throw AuthError.signInRequired }
        return session
    }

    func signOut() async {
        restoreGeneration += 1
        session = nil
        isRestoring = false
        restoreError = nil
        await KeychainStore.shared.delete()
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

    private func save(_ response: AuthResponse, expectedGeneration: Int) async throws {
        guard restoreGeneration == expectedGeneration else { throw AuthError.sessionChanged }
        guard let accessToken = response.accessToken,
              let refreshToken = response.refreshToken,
              let user = response.user else { throw AuthError.invalidResponse }
        let next = CommunitySession(accessToken: accessToken, refreshToken: refreshToken,
                                    expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600)),
                                    userID: user.id, email: user.email ?? "")
        let data = try JSONEncoder().encode(next)
        let (status, matches) = await KeychainStore.shared.writeAndVerify(data)
        guard status == errSecSuccess else {
            throw AuthError.keychain(status)
        }
        guard matches else { throw AuthError.keychainVerification }
        guard restoreGeneration == expectedGeneration else { throw AuthError.sessionChanged }
        restoreGeneration += 1
        session = next
        isRestoring = false
        restoreError = nil
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
        case signInRequired, sessionChanged, invalidResponse, keychain(OSStatus), keychainVerification
        var errorDescription: String? {
            switch self {
            case .signInRequired: "Sign in to publish a video."
            case .sessionChanged: "Your account changed during this request. Please try again."
            case .invalidResponse: "The sign-in service returned an invalid response."
            case .keychain(let status): "Couldn’t securely save your sign-in on this Mac (Keychain error \(status))."
            case .keychainVerification: "Saved sign-in did not match what Keychain returned. Please try again."
            }
        }
    }
}

private actor KeychainStore {
    static let shared = KeychainStore()
    private let service = "LiveDesk.CommunityAuth.v2"

    func read() -> (Data?, OSStatus) {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (result as? Data, status)
    }

    func writeAndVerify(_ data: Data) -> (OSStatus, Bool) {
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = baseQuery()
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return (status, false) }
        let (stored, readStatus) = read()
        return (readStatus, stored == data)
    }

    func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecUseDataProtectionKeychain as String: true]
    }
}
