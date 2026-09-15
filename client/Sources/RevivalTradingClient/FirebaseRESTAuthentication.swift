import Foundation

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

private struct CachedFirebaseSession: Sendable {
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
/// Sessions are memory-only for now: relaunch requires Google sign-in again.
public actor FirebaseRESTAuthentication {
    private let apiKey: String
    private let transport: TradingHTTPTransport
    private var cached: CachedFirebaseSession?
    private var refreshing: Task<CachedFirebaseSession, Error>?
    private var generation = 0

    public init(apiKey: String, transport: TradingHTTPTransport = URLSessionTradingTransport()) throws {
        guard !apiKey.isEmpty else { throw FirebaseAuthenticationError.invalidConfiguration }
        self.apiKey = apiKey
        self.transport = transport
    }

    public func signIn(googleIDToken: String) async throws -> FirebaseSession {
        guard !googleIDToken.isEmpty else { throw FirebaseAuthenticationError.signInRequired }
        signOut()
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
            cached = refreshed
            refreshing = nil
            return refreshed.publicSession
        } catch {
            if version == generation {
                refreshing = nil
                if case FirebaseAuthenticationError.rejected(let status) = error,
                   [400, 401, 403].contains(status) { cached = nil }
            }
            throw error
        }
    }

    public func signOut() {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        cached = nil
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
