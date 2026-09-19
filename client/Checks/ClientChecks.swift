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

private final class CheckSessionStore: FirebaseSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func load() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func save(_ value: Data?) throws { lock.lock(); defer { lock.unlock() }; data = value }
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
    static func roomBody(revision: Int, coins: Int = 0) throws -> String {
        let offer: [String:Any] = ["coins": coins, "cards": [String](), "slots": [Int]()]
        let room: [String:Any] = ["id": "room-1", "status": "open", "expiresAt": 9999999999999,
            "revision": revision, "self": "alice", "members": ["alice", "bob"],
            "offers": ["alice": offer, "bob": ["coins": 0, "cards": [String]()]],
            "ready": [String:Int](), "confirmed": [String:Int]()]
        return String(data: try JSONSerialization.data(withJSONObject: ["ok": true, "room": room]), encoding: .utf8)!
    }
    static func initialRoom() throws -> TradingResponse {
        try JSONDecoder().decode(TradingResponse.self, from: Data(roomBody(revision: 0).utf8))
    }
    static func main() async throws {
        let tests: [(String, () async throws -> Void)] = [
            ("logout during refresh cannot restore saved credentials", {
                let store = CheckSessionStore()
                let http = CheckTransport([(200, signInBody(expiry: 1)), (200, refreshBody)], delay: 30_000_000)
                let auth = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http, store: store)
                _ = try await auth.signIn(googleIDToken: "test-google")
                let refresh = Task { try await auth.session() }
                while await http.requests.count < 2 { await Task.yield() }
                try await auth.signOut()
                do { _ = try await refresh.value; throw CheckFailure.failed("Refresh restored logout") }
                catch is CancellationError {} catch FirebaseAuthenticationError.sessionChanged {}
                let saved = try store.load()
                try check(saved == nil, "Refresh persisted a logged-out account")
            }),
            ("saved Google session survives a new authentication instance", {
                let store = CheckSessionStore()
                let http = CheckTransport([(200, signInBody())])
                let first = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http, store: store)
                _ = try await first.signIn(googleIDToken: "test-google")
                let restarted = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http, store: store)
                let restored = try await restarted.session()
                let count = await http.requests.count
                try check(restored.uid == "alice" && count == 1, "Relaunch required another login")
                try await restarted.signOut()
                let signedOut = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http, store: store)
                do { _ = try await signedOut.session(); throw CheckFailure.failed("Logout survived restart") }
                catch FirebaseAuthenticationError.signInRequired {}
            }),
            ("expired saved session refreshes and persists rotated credentials", {
                let store = CheckSessionStore()
                let http = CheckTransport([(200, signInBody(expiry: 1)), (200, refreshBody)])
                let first = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http, store: store)
                _ = try await first.signIn(googleIDToken: "test-google")
                let restarted = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http, store: store)
                _ = try await restarted.session()
                let again = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http, store: store)
                let restored = try await again.session()
                let count = await http.requests.count
                try check(restored.idToken == "new-token" && count == 2, "Rotated session was not saved")
            }),
            ("network failure preserves saved login but revocation clears it", {
                let store = CheckSessionStore()
                let http = CheckTransport([(200, signInBody(expiry: 1)), (503, "{}"), (400, "{}")])
                let auth = try FirebaseRESTAuthentication(apiKey: "test-key", transport: http, store: store)
                _ = try await auth.signIn(googleIDToken: "test-google")
                do { _ = try await auth.session(); throw CheckFailure.failed("Failed refresh accepted") }
                catch FirebaseAuthenticationError.rejected(status: 503) {}
                let retained = try store.load()
                try check(retained != nil, "Network failure cleared login")
                do { _ = try await auth.session(); throw CheckFailure.failed("Revoked refresh accepted") }
                catch FirebaseAuthenticationError.rejected(status: 400) {}
                let removed = try store.load()
                try check(removed == nil, "Revoked login remained on disk")
            }),
            ("completed confirmation fetches inventory before exposing a receipt", {
                var completed = try JSONSerialization.jsonObject(with: Data(roomBody(revision: 0).utf8)) as! [String:Any]
                var room = completed["room"] as! [String:Any]
                room["status"] = "completed"
                completed["room"] = room
                let confirmation = String(data: try JSONSerialization.data(withJSONObject: completed), encoding: .utf8)!
                completed["inventory"] = ["coins": 100, "cards": ["cardA": 2]]
                completed["inventoryVersion"] = 2
                let receipt = String(data: try JSONSerialization.data(withJSONObject: completed), encoding: .utf8)!
                let http = CheckTransport([(200, confirmation), (200, receipt)])
                let session = try OriginalTradeSession(api: client(http), initial: initialRoom(), validateOffer: { _ in })
                let result = try await session.submit(.accept)
                try check(result.room?.isCompleted == true && result.inventory?.coins == 100 && result.inventoryVersion == 2, "Exposed incomplete receipt")
                _ = try await session.submit(.handshake)
                let requests = await http.requests
                let actions = try requests.map { (try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String:Any])["action"] as! String }
                try check(actions == ["confirm", "status"], "Missing receipt read or repeated transfer")
            }),
            ("peer card swaps clear old positions before rendering replacements", {
                func state(revision: Int, cards: [String], ready: Bool = false, accepted: Bool = false) throws -> OriginalTradePeerState {
                    var object = try JSONSerialization.jsonObject(with: Data(roomBody(revision: revision).utf8)) as! [String:Any]
                    var room = object["room"] as! [String:Any]
                    var offers = room["offers"] as! [String:Any]
                    offers["bob"] = ["coins": 10, "cards": cards, "slots": [0, 2]]
                    room["offers"] = offers
                    room["ready"] = ready ? ["bob": revision] : [:]
                    room["confirmed"] = accepted ? ["bob": revision] : [:]
                    object["room"] = room
                    let result = try JSONDecoder().decode(TradingResponse.self, from: JSONSerialization.data(withJSONObject: object))
                    return try OriginalTradePeerState(room: result.room!)
                }
                let old = try state(revision: 1, cards: ["cardA", "cardB"], ready: true, accepted: true)
                let new = try state(revision: 2, cards: ["cardB", "cardA"])
                let events = try new.events(after: old)
                try check(events == [.makeChanges, .deleted(slot: 0), .deleted(slot: 2),
                    .picked(slot: 0, cardID: "cardB"), .picked(slot: 2, cardID: "cardA")], "Incorrect swap or readiness event order")
                let repeated = try new.events(after: new)
                try check(repeated.isEmpty, "Repeated poll replayed peer events")
                let confirmed = try state(revision: 2, cards: ["cardB", "cardA"], ready: true, accepted: true)
                let confirmation = try confirmed.events(after: new)
                // Peer acceptance is intentionally not rendered into the legacy
                // PACYBITS UI before the backend room reaches completed; doing so
                // starts the retired GameKit completion spinner.
                try check(confirmation == [.ready], "Peer confirmation should wait for backend completion")
                let malformed = try state(revision: 2, cards: ["cardA", "cardB"])
                do { _ = try malformed.events(after: new); throw CheckFailure.failed("Offer changed without a revision") }
                catch TradingClientError.invalidResponse {}
            }),
            ("native actions wait for the previous server revision", {
                let http = CheckTransport([(200, try roomBody(revision: 1, coins: 10)),
                                           (200, try roomBody(revision: 2, coins: 20))], delay: 30_000_000)
                let session = try OriginalTradeSession(api: client(http), initial: initialRoom(), validateOffer: { _ in })
                let first = Task { try await session.submit(.coins(10)) }
                while await http.requests.isEmpty { await Task.yield() }
                let second = Task { try await session.submit(.coins(20)) }
                _ = try await first.value
                _ = try await second.value
                let requests = await http.requests
                let bodies = try requests.map { try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String:Any] }
                try check(bodies.count == 2, "Lost or duplicated a native action")
                try check(bodies[0]["revision"] as? Int == 0 && bodies[1]["revision"] as? Int == 1, "Used stale revision")
                try check((bodies[1]["offer"] as? [String:Any])?["coins"] as? Int == 20, "Lost the second offer")
            }),
            ("uncertain native mutation requires refresh before another action", {
                let http = CheckTransport([(503, #"{"error":"TEMPORARILY_UNAVAILABLE"}"#),
                                           (200, try roomBody(revision: 4)), (200, try roomBody(revision: 4))])
                let session = try OriginalTradeSession(api: client(http), initial: initialRoom(), validateOffer: { _ in })
                do { _ = try await session.submit(.coins(10)); throw CheckFailure.failed("Expected server failure") }
                catch TradingClientError.server(_, _) {}
                do { _ = try await session.submit(.ready); throw CheckFailure.failed("Mutation used uncertain state") }
                catch TradingClientError.invalidResponse {}
                let count = await http.requests.count
                try check(count == 1, "Mutation was replayed or bypassed refresh")
                _ = try await session.refresh()
                _ = try await session.submit(.ready)
                let last = await http.requests.last!
                let body = try JSONSerialization.jsonObject(with: last.httpBody!) as! [String:Any]
                try check(body["action"] as? String == "ready" && body["revision"] as? Int == 4, "Refresh did not restore current revision")
            }),
            ("native handshake never authorizes a server transfer", {
                let http = CheckTransport([])
                let session = try OriginalTradeSession(api: client(http), initial: initialRoom(), validateOffer: { _ in })
                let result = try await session.submit(.handshake)
                try check(result.room?.isCompleted == false, "Handshake manufactured completion")
                let count = await http.requests.count
                try check(count == 0, "Handshake submitted a transfer")
            }),
            ("original card slots survive deletion, sorting and server snapshots", {
                var offer = OriginalTradeOffer()
                try offer.apply(.picked(slot: 0, cardID: "cardB"))
                try offer.apply(.picked(slot: 2, cardID: "cardA"))
                try offer.apply(.coins(50))
                let server = TradeOffer(coins: 50, cards: ["cardA", "cardB"], slots: [2, 0])
                let restored = try OriginalTradeOffer(server: server)
                try check(restored == offer, "Server sorting moved original card positions")
                try offer.apply(.deleted(slot: 0))
                try check(offer.serverOffer.cards == ["cardA"] && offer.serverOffer.slots == [2], "Deletion collapsed a gap")
                let before = offer
                do {
                    try offer.apply(.picked(slot: 1, cardID: "cardA"))
                    throw CheckFailure.failed("Duplicate card accepted")
                } catch TradingClientError.invalidResponse {}
                try check(offer == before, "Rejected action mutated offer")
                let handled = try offer.apply(.handshake)
                try check(!handled && offer == before, "Handshake changed inventory offer")
            }),
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
                try await auth.signOut()
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
                try await auth.signOut()
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
