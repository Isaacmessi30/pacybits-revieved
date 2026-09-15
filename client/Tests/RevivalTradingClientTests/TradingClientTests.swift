import XCTest
@testable import RevivalTradingClient

private actor StubTransport: TradingHTTPTransport {
    var requests: [URLRequest] = []
    let code: Int
    let body: String
    init(code: Int = 200, body: String = #"{"ok":true,"room":null,"queued":false,"inventory":{"coins":0,"cards":{}}}"#) {
        self.code = code; self.body = body
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}
private actor SessionBox {
    var session = FirebaseSession(uid: "alice", idToken: "test-token")
    func get() -> FirebaseSession { session }
    func switchUser() { session = FirebaseSession(uid: "bob", idToken: "new-token") }
}
final class TradingClientTests: XCTestCase {
    private let endpoint = URL(string: "https://example.test/trading")!
    func testRejectsInsecureRemoteEndpoint() {
        XCTAssertThrowsError(try TradingClient(endpoint: URL(string: "http://example.test/trading")!, allowLocalEmulator: true) {
            FirebaseSession(uid: "alice", idToken: "token")
        })
    }
    func testAllowsExplicitLoopbackForEmulator() throws {
        _ = try TradingClient(endpoint: URL(string: "http://127.0.0.1:5001/trading")!, allowLocalEmulator: true) {
            FirebaseSession(uid: "alice", idToken: "token")
        }
    }
    func testSendsTokenAndActionWithoutClientIdentityOrBalances() async throws {
        let http = StubTransport()
        let client = try TradingClient(endpoint: endpoint, transport: http) {
            FirebaseSession(uid: "alice", idToken: "test-token")
        }
        let result = try await client.status()
        XCTAssertEqual(result.inventory?.coins, 0)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: String]
        XCTAssertEqual(body, ["action": "status"])
    }
    func testStaleRevisionIsReturnedAndMutationNotRetried() async throws {
        let http = StubTransport(code: 409, body: #"{"ok":false,"error":"STALE_REVISION"}"#)
        let client = try TradingClient(endpoint: endpoint, transport: http) {
            FirebaseSession(uid: "alice", idToken: "test-token")
        }
        do {
            _ = try await client.joinInvitation(roomID: "room-a")
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? TradingClientError, .server(status: 409, code: "STALE_REVISION"))
        }
        let count = await http.requests.count
        XCTAssertEqual(count, 1)
    }
    func testAccountSwitchRequiresExplicitReset() async throws {
        let sessions = SessionBox()
        let http = StubTransport()
        let client = try TradingClient(endpoint: endpoint, transport: http) { await sessions.get() }
        _ = try await client.status()
        await sessions.switchUser()
        do {
            _ = try await client.status()
            XCTFail("Expected account switch rejection")
        } catch { XCTAssertEqual(error as? TradingClientError, .accountChanged) }
        await client.resetSession()
        _ = try await client.status()
        let count = await http.requests.count
        XCTAssertEqual(count, 2)
    }
    func testMalformedSuccessIsRejected() async throws {
        let http = StubTransport(body: #"{"ok":false}"#)
        let client = try TradingClient(endpoint: endpoint, transport: http) {
            FirebaseSession(uid: "alice", idToken: "test-token")
        }
        do { _ = try await client.status(); XCTFail("Expected invalid response") }
        catch { XCTAssertEqual(error as? TradingClientError, .invalidResponse) }
    }
}
