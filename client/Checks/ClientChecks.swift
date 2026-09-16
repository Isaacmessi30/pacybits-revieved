import Foundation

private enum CheckFailure: Error { case failed(String) }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure.failed(message) }
}
private actor CheckTransport: TradingHTTPTransport {
    private(set) var requests: [URLRequest] = []
    var responses: [(Int, String)]
    let delay: UInt64
    init(_ responses: [(Int, String)], delay: UInt64 = 0) { self.responses = responses; self.delay = delay }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw CheckFailure.failed("Unexpected HTTP request") }
        let (code, body) = responses.removeFirst()
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}
private actor CheckSessionBox {
    var uid = "alice"
    func current() -> FirebaseSession { FirebaseSession(uid: uid, idToken: "test-token") }
    func change() { uid = "bob" }
}

@main
struct ClientChecks {
    static let endpoint = URL(string: "https://example.test/trading")!
    static let statusBody = #"{"ok":true,"room":null,"queued":false,"inventory":{"coins":0,"cards":{}}}"#
    static func signInBody(expiry: Int = 3600) -> String {
        "{\"localId\":\"alice\",\"idToken\":\"test-token\",\"refreshToken\":\"test-refresh\",\"expiresIn\":\"\(expiry)\"}"
    }
    static let refreshBody = #"{"user_id":"alice","id_token":"new-token","refresh_token":"new-refresh","expires_in":"3600"}"#
    private static func client(_ http: CheckTransport) throws -> TradingClient {
        try TradingClient(endpoint: endpoint, transport: http) { FirebaseSession(uid: "alice", idToken: "test-token") }
    }
    static func main() async throws {
        let tests: [(String, () async throws -> Void)] = [
            ("rejects remote HTTP even when emulator mode is enabled", {
                do {
                    _ = try TradingClient(endpoint: URL(string: "http://example.test")!, allowLocalEmulator: true) {
                        FirebaseSession(uid: "a", idToken: "t")
                    }
                    throw CheckFailure.failed("Insecure endpoint accepted")
                } catch TradingClientError.invalidEndpoint {}
            }),
            ("accepts explicit loopback emulator endpoint", {
                _ = try TradingClient(endpoint: URL(string: "http://127.0.0.1:5001/trading")!, allowLocalEmulator: true) {
                    FirebaseSession(uid: "a", idToken: "t")
                }
            }),
            ("sends only server-supported fields and authenticates every request", {
                let http = CheckTransport([(200, statusBody)])
                let result = try await client(http).status()
                try check(result.inventory?.coins == 0, "Inventory decoding failed")
                let requests = await http.requests
                try check(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "Missing token")
                let body = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: String]
                try check(body == ["action": "status"], "Unexpected request fields")
            }),
            ("does not automatically retry a rejected mutation", {
                let http = CheckTransport([(409, #"{"error":"STALE_REVISION"}"#)])
                do {
                    _ = try await client(http).joinInvitation(roomID: "room-1")
                    throw CheckFailure.failed("Expected stale revision")
                } catch TradingClientError.server(let status, let code) {
                    try check(status == 409 && code == "STALE_REVISION", "Wrong server error")
                }
                let count = await http.requests.count
                try check(count == 1, "Mutation was retried")
            }),
            ("account change requires session reset", {
                let http = CheckTransport([(200, statusBody), (200, statusBody)])
                let session = CheckSessionBox()
                let api = try TradingClient(endpoint: endpoint, transport: http) { await session.current() }
                _ = try await api.status()
                await session.change()
                do { _ = try await api.status(); throw CheckFailure.failed("Account changed silently") }
                catch TradingClientError.accountChanged {}
                await api.resetSession()
                _ = try await api.status()
            }),
            ("logout discards in-flight trade responses", {
                let http = CheckTransport([(200, statusBody)], delay: 30_000_000)
                let api = try client(http)
                let request = Task { try await api.status() }
                while await http.requests.isEmpty { await Task.yield() }
                await api.resetSession()
                do { _ = try await request.value; throw CheckFailure.failed("Old account response returned") }
                catch TradingClientError.accountChanged {}
            }),
            ("malformed successful response is rejected", {
                let http = CheckTransport([(200, #"{"ok":false}"#)])
                do { _ = try await client(http).status(); throw CheckFailure.failed("Invalid response accepted") }
                catch TradingClientError.invalidResponse {}
            }),
            ("Google credential exchange uses Firebase HTTPS and proper form encoding", {
                let http = CheckTransport([(200, signInBody())])
                let auth = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http)
                let result = try await auth.signIn(googleIDToken: "a+b&c=d")
                try check(result.uid == "alice", "Wrong Firebase UID")
                let requests = await http.requests
                try check(requests[0].url?.host == "identitytoolkit.googleapis.com", "Wrong endpoint")
                let body = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
                try check(body["postBody"] as? String == "id_token=a%2Bb%26c%3Dd&providerId=google.com", "Bad credential encoding")
                _ = try await auth.session()
                let count = await http.requests.count
                try check(count == 1, "Valid token unnecessarily refreshed")
            }),
            ("Game Center exchange binds bundle and encodes Apple proof", {
                let http = CheckTransport([(200, signInBody())])
                let auth = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http)
                let proof = GameCenterCredential(teamPlayerID: "team", gamePlayerID: "game",
                    publicKeyURL: URL(string: "https://static.gc.apple.com/key")!,
                    signature: Data([0, 255]), salt: Data([1, 2]), timestamp: 123456789,
                    displayName: "Player")
                let result = try await auth.signIn(gameCenter: proof, bundleID: "com.example.game")
                try check(result.uid == "alice", "Firebase identity missing")
                let requests = await http.requests
                let request = requests[0]
                try check(request.url?.path == "/v1/accounts:signInWithGameCenter", "Wrong exchange")
                try check(request.value(forHTTPHeaderField: "x-ios-bundle-identifier") == "com.example.game", "Missing bundle binding")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
                try check(body["signature"] == "AP8=" && body["salt"] == "AQI=", "Bad proof encoding")
                try check(body["timestamp"] == "123456789" && body["gamePlayerId"] == "game", "Wrong proof fields")
                await auth.signOut()
                do { _ = try await auth.session(); throw CheckFailure.failed("Game Center session survived logout") }
                catch FirebaseAuthenticationError.signInRequired {}
            }),
            ("Google callback rejects wrong state, redirect and duplicate parameters", {
                let redirect = "com.googleusercontent.apps.test:/oauth2redirect"
                let code = try GoogleOAuthCallback.code(from: URL(string: redirect + "?state=expected&code=abc")!, redirectURI: redirect, expectedState: "expected")
                try check(code == "abc", "Valid callback rejected")
                for callback in [
                    redirect + "?state=wrong&code=abc",
                    redirect + "?state=expected&state=expected&code=abc",
                    redirect + "?state=expected&code=abc&code=def",
                    redirect + "?state=expected&error=access_denied",
                    redirect + "?state=expected&code=abc#fragment",
                    "com.googleusercontent.apps.other:/oauth2redirect?state=expected&code=abc",
                    "com.googleusercontent.apps.test:/wrong?state=expected&code=abc"
                ] {
                    do {
                        _ = try GoogleOAuthCallback.code(from: URL(string: callback)!, redirectURI: redirect, expectedState: "expected")
                        throw CheckFailure.failed("Unsafe callback accepted")
                    } catch FirebaseAuthenticationError.invalidResponse {}
                }
            }),
            ("concurrent callers share one token refresh", {
                let http = CheckTransport([(200, signInBody(expiry: 1)), (200, refreshBody)], delay: 20_000_000)
                let auth = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http)
                _ = try await auth.signIn(googleIDToken: "test-google")
                async let first = auth.session()
                async let second = auth.session()
                let results = try await [first, second]
                try check(results.allSatisfy { $0.idToken == "new-token" }, "Refresh results differ")
                let count = await http.requests.count
                try check(count == 2, "Duplicate refresh request")
            }),
            ("refresh cannot silently switch account identity", {
                let bad = refreshBody.replacingOccurrences(of: "alice", with: "bob")
                let http = CheckTransport([(200, signInBody(expiry: 1)), (200, bad)])
                let auth = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http)
                _ = try await auth.signIn(googleIDToken: "test-google")
                do { _ = try await auth.session(); throw CheckFailure.failed("Cross-account refresh accepted") }
                catch FirebaseAuthenticationError.invalidResponse {}
            }),
            ("revoked refresh requires login again", {
                let http = CheckTransport([(200, signInBody(expiry: 1)), (400, #"{"error":{"message":"TOKEN_EXPIRED"}}"#)])
                let auth = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http)
                _ = try await auth.signIn(googleIDToken: "test-google")
                do { _ = try await auth.session(); throw CheckFailure.failed("Revoked refresh accepted") }
                catch FirebaseAuthenticationError.rejected(status: 400) {}
                do { _ = try await auth.session(); throw CheckFailure.failed("Revoked session kept") }
                catch FirebaseAuthenticationError.signInRequired {}
            }),
            ("sign-out removes the cached Firebase session", {
                let http = CheckTransport([(200, signInBody())])
                let auth = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http)
                _ = try await auth.signIn(googleIDToken: "test-google")
                await auth.signOut()
                do { _ = try await auth.session(); throw CheckFailure.failed("Session survived logout") }
                catch FirebaseAuthenticationError.signInRequired {}
            })
        ]
        for (name, run) in tests {
            try await run()
            print("PASS: \(name)")
        }
        print("\(tests.count) client checks passed (mock HTTP, macOS build; no live OAuth or iPhone test).")
    }
}
