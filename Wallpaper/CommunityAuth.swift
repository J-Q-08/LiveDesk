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
    struct PublishingAccount: Equatable {
        let userID: String
        fileprivate let generation: Int
    }

    static let shared = CommunityAuth()
    @Published private(set) var session: CommunitySession?
    @Published private(set) var restoreError: String?
    @Published private(set) var isRestoring = true
    @Published private(set) var isSigningOut = false
    private var restoreGeneration = 0
    private var refreshRequest: (id: UUID, task: Task<CommunitySession, Error>)?

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
        guard !isSigningOut, let current = session else { throw AuthError.signInRequired }
        if current.expiresAt > Date().addingTimeInterval(60) { return current }
        let task: Task<CommunitySession, Error>
        if let request = refreshRequest {
            task = request.task
        } else {
            let generation = restoreGeneration
            let id = UUID()
            task = Task {
                defer {
                    if refreshRequest?.id == id { refreshRequest = nil }
                }
                return try await refreshSession(current, generation: generation)
            }
            refreshRequest = (id, task)
        }
        let refreshed = try await task.value
        guard !isSigningOut, session?.refreshToken == refreshed.refreshToken else {
            throw AuthError.sessionChanged
        }
        return refreshed
    }

    func publishingAccount() throws -> PublishingAccount {
        guard !isSigningOut, let session else { throw AuthError.signInRequired }
        return PublishingAccount(userID: session.userID, generation: restoreGeneration)
    }

    func validSession(for account: PublishingAccount) async throws -> CommunitySession {
        guard try publishingAccount() == account else { throw AuthError.sessionChanged }
        let current = try await validSession()
        guard try publishingAccount() == account else { throw AuthError.sessionChanged }
        return current
    }

    private func refreshSession(_ current: CommunitySession, generation: Int) async throws -> CommunitySession {
        do {
            let response = try await authRequest(path: "auth/v1/token?grant_type=refresh_token",
                                                 body: ["refresh_token": current.refreshToken])
            try await save(response, expectedGeneration: generation)
            guard let session, !isSigningOut else { throw AuthError.signInRequired }
            return session
        } catch AuthError.expiredSession {
            guard restoreGeneration == generation else { throw AuthError.sessionChanged }
            try await signOut()
            restoreError = AuthError.expiredSession.errorDescription
            throw AuthError.expiredSession
        }
    }

    func signOut() async throws {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        restoreGeneration += 1
        refreshRequest = nil
        let status = await KeychainStore.shared.delete()
        guard status == errSecSuccess else { throw AuthError.keychainDelete(status) }
        session = nil
        isRestoring = false
        restoreError = nil
    }

    private func authRequest(path: String, body: [String: String]) async throws -> AuthResponse {
        // URLComponents keeps the grant_type query separate from the path.
        guard let url = URL(string: path, relativeTo: CommunityService.projectURL) else {
            throw AuthError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(CommunityService.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if path == "auth/v1/token?grant_type=refresh_token",
           let http = response as? HTTPURLResponse, (400..<500).contains(http.statusCode),
           let failure = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = (failure["error_code"] as? String) ?? (failure["code"] as? String),
           Self.expiredSessionCodes.contains(code) {
            throw AuthError.expiredSession
        }
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

    private static let expiredSessionCodes: Set<String> = [
        "refresh_token_not_found", "refresh_token_already_used", "session_expired", "session_not_found"
    ]

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
        case signInRequired, expiredSession, sessionChanged, invalidResponse, keychain(OSStatus), keychainDelete(OSStatus), keychainVerification
        var errorDescription: String? {
            switch self {
            case .signInRequired: "Sign in to publish a video."
            case .expiredSession: "Your saved sign-in has expired. Sign in again on the Account page."
            case .sessionChanged: "Your account changed during this request. Please try again."
            case .invalidResponse: "The sign-in service returned an invalid response."
            case .keychain(let status): "Couldn’t securely save your sign-in on this Mac (Keychain error \(status))."
            case .keychainDelete(let status): "Couldn’t remove your saved sign-in (Keychain error \(status)). Try signing out again."
            case .keychainVerification: "Saved sign-in did not match what Keychain returned. Please try again."
            }
        }
    }
}

private actor KeychainStore {
    static let shared = KeychainStore()

    func read() -> (Data?, OSStatus) {
        let protected = read(dataProtection: true)
        guard protected.1 == errSecItemNotFound || protected.1 == errSecMissingEntitlement else {
            return protected
        }
        return read(dataProtection: false)
    }

    private func read(dataProtection: Bool) -> (Data?, OSStatus) {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (result as? Data, status)
    }

    func writeAndVerify(_ data: Data) -> (OSStatus, Bool) {
        let protected = writeAndVerify(data, dataProtection: true)
        guard protected.0 == errSecMissingEntitlement else { return protected }
        return writeAndVerify(data, dataProtection: false)
    }

    private func writeAndVerify(_ data: Data, dataProtection: Bool) -> (OSStatus, Bool) {
        let query = baseQuery(dataProtection: dataProtection)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            if dataProtection {
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return (status, false) }
        let (stored, readStatus) = read(dataProtection: dataProtection)
        return (readStatus, stored == data)
    }

    func delete() -> OSStatus {
        // Remove the fallback first so a partial failure cannot expose an older session on restore.
        let fallbackStatus = SecItemDelete(baseQuery(dataProtection: false) as CFDictionary)
        guard fallbackStatus == errSecSuccess || fallbackStatus == errSecItemNotFound else {
            return fallbackStatus
        }
        let protectedStatus = SecItemDelete(baseQuery(dataProtection: true) as CFDictionary)
        if protectedStatus == errSecItemNotFound || protectedStatus == errSecMissingEntitlement {
            return errSecSuccess
        }
        return protectedStatus
    }

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        if dataProtection {
            return [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "LiveDesk.CommunityAuth.v2",
                    kSecUseDataProtectionKeychain as String: true]
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jeffrey.Wallpaper"
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "\(bundleID).LiveDesk.LoginSession",
                kSecAttrAccount as String: "session"]
    }
}
