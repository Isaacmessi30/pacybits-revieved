import Foundation
import Security

public struct FirebaseProjectConfiguration: Decodable, Sendable {
    public let projectID: String
    public let bundleID: String
    public let apiKey: String
    public let clientID: String
    public let reversedClientID: String
    enum CodingKeys: String, CodingKey {
        case projectID = "PROJECT_ID", bundleID = "BUNDLE_ID", apiKey = "API_KEY"
        case clientID = "CLIENT_ID", reversedClientID = "REVERSED_CLIENT_ID"
    }
    public static func load(plist: Data) throws -> Self {
        let config = try PropertyListDecoder().decode(Self.self, from: plist)
        guard !config.projectID.isEmpty, !config.bundleID.isEmpty, !config.apiKey.isEmpty,
              config.clientID.hasSuffix(".apps.googleusercontent.com"),
              !config.reversedClientID.isEmpty else { throw FirebaseAuthenticationError.invalidConfiguration }
        return config
    }
}

public enum FirebaseAuthenticationError: Error, Equatable {
    case invalidConfiguration
    case signInRequired
    case sessionChanged
    case invalidResponse
    case rejected(status: Int)
}

private struct CachedFirebaseSession: Codable, Sendable {
    let uid: String
    let idToken: String
    let refreshToken: String
    let expiresAt: Date
    var publicSession: FirebaseSession { FirebaseSession(uid: uid, idToken: idToken) }
}
private struct SignInResponse: Decodable {
    let localId: String
    let idToken: String
    let refreshToken: String
    let expiresIn: String
}
private struct RefreshResponse: Decodable {
    let user_id: String
    let id_token: String
    let refresh_token: String
    let expires_in: String
}

/// Uses Firebase's HTTPS API, avoiding a second Firebase runtime inside the legacy IPA.
/// Optional secure storage restores sessions across launches.
public actor FirebaseRESTAuthentication {
    private let apiKey: String
    private let store: FirebaseSessionStore?
    private let transport: TradingHTTPTransport
    private var cached: CachedFirebaseSession?
    private var refreshing: Task<CachedFirebaseSession, Error>?
    private var generation = 0

    public init(apiKey: String, transport: TradingHTTPTransport = URLSessionTradingTransport(), store: FirebaseSessionStore? = nil) throws {
        guard !apiKey.isEmpty else { throw FirebaseAuthenticationError.invalidConfiguration }
        self.apiKey = apiKey
        self.transport = transport
        self.store = store
        if let data = try store?.load() {
            guard data.count <= 65536,
                  let restored = try? JSONDecoder().decode(CachedFirebaseSession.self, from: data),
                  !restored.uid.isEmpty, !restored.idToken.isEmpty, !restored.refreshToken.isEmpty,
                  restored.expiresAt.timeIntervalSince1970.isFinite else {
                try store?.save(nil)
                return
            }
            cached = restored
        }
    }

    public func signIn(googleIDToken: String) async throws -> FirebaseSession {
        guard !googleIDToken.isEmpty else { throw FirebaseAuthenticationError.signInRequired }
        try signOut()
        let version = generation
        var request = URLRequest(url: endpoint("https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let postBody = Self.form(["id_token": googleIDToken, "providerId": "google.com"])
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "postBody": postBody,
            // Firebase's native credential exchange parameter; not an OAuth browser redirect.
            "requestUri": "http://localhost",
            "returnSecureToken": true
        ])
        let (data, http) = try await transport.send(request)
        guard version == generation else { throw FirebaseAuthenticationError.sessionChanged }
        guard http.statusCode == 200 else { throw FirebaseAuthenticationError.rejected(status: http.statusCode) }
        guard data.count <= 65536, let response = try? JSONDecoder().decode(SignInResponse.self, from: data) else {
            throw FirebaseAuthenticationError.invalidResponse
        }
        let session = try Self.makeSession(uid: response.localId, token: response.idToken,
                                          refresh: response.refreshToken, expiry: response.expiresIn)
        try store?.save(JSONEncoder().encode(session))
        cached = session
        return session.publicSession
    }

    /// Firebase verifies Apple's fresh signature. A nickname alone is never a credential.
    public func signIn(gameCenter credential: GameCenterCredential, bundleID: String) async throws -> FirebaseSession {
        guard !bundleID.isEmpty, !credential.teamPlayerID.isEmpty, !credential.gamePlayerID.isEmpty,
              credential.publicKeyURL.scheme == "https", !credential.signature.isEmpty,
              !credential.salt.isEmpty, credential.timestamp > 0 else {
            throw FirebaseAuthenticationError.invalidConfiguration
        }
        try signOut()
        let version = generation
        var request = URLRequest(url: endpoint("https://identitytoolkit.googleapis.com/v1/accounts:signInWithGameCenter"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(bundleID, forHTTPHeaderField: "x-ios-bundle-identifier")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "playerId": credential.playerID,
            "teamPlayerId": credential.teamPlayerID,
            "gamePlayerId": credential.gamePlayerID,
            "publicKeyUrl": credential.publicKeyURL.absoluteString,
            "signature": credential.signature.base64EncodedString(),
            "salt": credential.salt.base64EncodedString(),
            "timestamp": String(credential.timestamp),
            "displayName": credential.displayName
        ])
        let (data, http) = try await transport.send(request)
        guard version == generation else { throw FirebaseAuthenticationError.sessionChanged }
        guard http.statusCode == 200 else { throw FirebaseAuthenticationError.rejected(status: http.statusCode) }
        guard data.count <= 65536, let response = try? JSONDecoder().decode(SignInResponse.self, from: data) else {
            throw FirebaseAuthenticationError.invalidResponse
        }
        let session = try Self.makeSession(uid: response.localId, token: response.idToken,
                                          refresh: response.refreshToken, expiry: response.expiresIn)
        try store?.save(JSONEncoder().encode(session))
        cached = session
        return session.publicSession
    }

    public func session() async throws -> FirebaseSession {
        guard let current = cached else { throw FirebaseAuthenticationError.signInRequired }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.publicSession }
        let version = generation
        let task: Task<CachedFirebaseSession, Error>
        if let existing = refreshing { task = existing }
        else {
            var request = URLRequest(url: endpoint("https://securetoken.googleapis.com/v1/token"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.form(["grant_type": "refresh_token", "refresh_token": current.refreshToken]).utf8)
            let httpTransport = transport
            let refreshRequest = request
            task = Task {
                let (data, http) = try await httpTransport.send(refreshRequest)
                guard http.statusCode == 200 else { throw FirebaseAuthenticationError.rejected(status: http.statusCode) }
                guard data.count <= 65536, let response = try? JSONDecoder().decode(RefreshResponse.self, from: data),
                      response.user_id == current.uid else { throw FirebaseAuthenticationError.invalidResponse }
                return try Self.makeSession(uid: response.user_id, token: response.id_token,
                                            refresh: response.refresh_token, expiry: response.expires_in)
            }
            refreshing = task
        }
        do {
            let refreshed = try await task.value
            guard version == generation else { throw FirebaseAuthenticationError.sessionChanged }
            try store?.save(JSONEncoder().encode(refreshed))
            cached = refreshed
            refreshing = nil
            return refreshed.publicSession
        } catch {
            if version == generation {
                refreshing = nil
                if case FirebaseAuthenticationError.rejected(let status) = error,
                   [400, 401, 403].contains(status) {
                    cached = nil
                    try store?.save(nil)
                }
            }
            throw error
        }
    }

    public func signOut() throws {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        cached = nil
        try store?.save(nil)
    }

    private func endpoint(_ base: String) -> URL {
        var url = URLComponents(string: base)!
        url.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return url.url!
    }
    private static func makeSession(uid: String, token: String, refresh: String, expiry: String) throws -> CachedFirebaseSession {
        guard !uid.isEmpty, !token.isEmpty, !refresh.isEmpty, let seconds = Double(expiry),
              seconds.isFinite, seconds > 0, seconds <= 86400 else { throw FirebaseAuthenticationError.invalidResponse }
        return CachedFirebaseSession(uid: uid, idToken: token, refreshToken: refresh,
                                     expiresAt: Date().addingTimeInterval(seconds))
    }
    private static func form(_ values: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return values.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
            + values[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
    }
}

public struct GameCenterCredential: Sendable {
    public let playerID: String
    public let teamPlayerID: String
    public let gamePlayerID: String
    public let publicKeyURL: URL
    public let signature: Data
    public let salt: Data
    public let timestamp: UInt64
    public let displayName: String

    public init(playerID: String = "", teamPlayerID: String, gamePlayerID: String,
                publicKeyURL: URL, signature: Data, salt: Data, timestamp: UInt64, displayName: String) {
        self.playerID = playerID
        self.teamPlayerID = teamPlayerID
        self.gamePlayerID = gamePlayerID
        self.publicKeyURL = publicKeyURL
        self.signature = signature
        self.salt = salt
        self.timestamp = timestamp
        self.displayName = displayName
    }
}

/// Implementations must synchronize access and must not log credential data.
public protocol FirebaseSessionStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data?) throws
}

public struct KeychainFirebaseSessionStore: FirebaseSessionStore {
    private let service: String
    public init(projectID: String, bundleID: String) {
        service = bundleID + ".revival.google-session." + projectID
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "firebase-session",
         kSecAttrSynchronizable as String: false]
    }
    public func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SessionStorageError(status: status) }
        return data
    }
    public func save(_ data: Data?) throws {
        guard let data = data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SessionStorageError(status: status) }
            return
        }
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SessionStorageError(status: status) }
    }
}
public struct SessionStorageError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? { "Secure sign-in storage is unavailable (\(status)). Unlock your device and try again." }
}
