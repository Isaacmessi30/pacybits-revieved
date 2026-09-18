import Foundation

public struct FirebaseSession: Sendable {
    public let uid: String
    public let idToken: String
    public init(uid: String, idToken: String) {
        self.uid = uid
        self.idToken = idToken
    }
}

public struct TradeOffer: Codable, Equatable, Sendable {
    public let coins: Int
    public let cards: [String]
    public let slots: [Int]?
    public init(coins: Int, cards: [String], slots: [Int]? = nil) {
        self.coins = coins
        self.cards = cards
        self.slots = slots
    }
}

public struct TradeInventory: Codable, Equatable, Sendable {
    public let coins: Int
    public let cards: [String: Int]
    public init(coins: Int, cards: [String: Int]) { self.coins = coins; self.cards = cards }
}

public struct TradeSignal: Codable, Equatable, Sendable {
    public let seq: Int
    public let type: String
    public let payload: String
}

public struct TradeRoom: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let expiresAt: Int64
    public let revision: Int
    public let selfKey: String
    public let members: [String]
    public let offers: [String: TradeOffer]
    public let ready: [String: Int]
    public let confirmed: [String: Int]
    public let handshakes: [String: String]?
    public let signals: [String: [TradeSignal]]?
    public let closedAt: Int64?
    public let botPartner: Bool?
    public let testPartner: Bool?

    enum CodingKeys: String, CodingKey {
        case id, status, expiresAt, revision, members, offers, ready, confirmed, handshakes, signals, closedAt, botPartner, testPartner
        case selfKey = "self"
    }
    public var isCompleted: Bool { status == "completed" }
    public var peerHandshake: String? {
        guard let peer = members.first(where: { $0 != selfKey }) else { return nil }
        return handshakes?[peer]
    }
    public var peerSignals: [TradeSignal] {
        guard let peer = members.first(where: { $0 != selfKey }) else { return [] }
        return signals?[peer] ?? []
    }
}

public struct TradingResponse: Decodable, Sendable {
    public let ok: Bool
    public let room: TradeRoom?
    public let queued: Bool?
    public let inventory: TradeInventory?
    public let inventoryReady: Bool?
    public let inventoryVersion: Int?
    public let inventoryOrigin: String?
    public let preserveFirstCopy: Bool?
}

public enum TradingClientError: Error, Equatable {
    case invalidEndpoint
    case missingSession
    case accountChanged
    case invalidResponse
    case server(status: Int, code: String)
}

public protocol TradingHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionTradingTransport: TradingHTTPTransport {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 45
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TradingClientError.invalidResponse }
        return (data, http)
    }
}

private struct TradeRequest: Encodable {
    let action: String
    var roomId: String?
    var revision: Int?
    var offer: TradeOffer?
    var inventory: TradeInventory?
    var preserveFirstCopy: Bool?
    var expectedInventoryVersion: Int?
    var payload: String?
    var signalType: String?
    var signalPayload: String?
    var scope: String?
    var targetLegacyId: String?
    var legacyId: String?
    var cardIds: [String]?
}
private struct ErrorResponse: Decodable { let error: String }

/// Typed transport only. The host must obtain a fresh Google-backed Firebase session.
/// No mutations are automatically retried after an uncertain network result.
public actor TradingClient {
    private let endpoint: URL
    private let transport: TradingHTTPTransport
    private let sessionProvider: @Sendable () async throws -> FirebaseSession
    private var uid: String?
    private var generation = 0

    public init(endpoint: URL,
                allowLocalEmulator: Bool = false,
                transport: TradingHTTPTransport = URLSessionTradingTransport(),
                sessionProvider: @escaping @Sendable () async throws -> FirebaseSession) throws {
        let isLocal = allowLocalEmulator && endpoint.scheme == "http"
            && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(endpoint.host ?? "")
        guard (endpoint.scheme == "https" || isLocal),
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else {
            throw TradingClientError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.transport = transport
        self.sessionProvider = sessionProvider
    }

    public func resetSession() {
        generation += 1
        uid = nil
    }

    public func status(roomID: String? = nil) async throws -> TradingResponse {
        try await send(TradeRequest(action: "status", roomId: roomID))
    }
    public func register(legacyID: String? = nil) async throws -> TradingResponse {
        try await send(TradeRequest(action: "register", legacyId: legacyID))
    }
    public func importLegacyInventory(_ inventory: TradeInventory, preserveFirstCopy: Bool = false) async throws -> TradingResponse {
        try await send(TradeRequest(action: "importLegacyInventory", inventory: inventory, preserveFirstCopy: preserveFirstCopy ? true : nil))
    }
    public func replaceInventory(_ inventory: TradeInventory, expectedVersion: Int, preserveFirstCopy: Bool = true) async throws -> TradingResponse {
        try await send(TradeRequest(action: "replaceInventory", inventory: inventory,
                                    preserveFirstCopy: preserveFirstCopy,
                                    expectedInventoryVersion: expectedVersion))
    }
    public func createInvitation() async throws -> TradingResponse {
        try await send(TradeRequest(action: "invite"))
    }
    public func joinInvitation(roomID: String) async throws -> TradingResponse {
        try await send(TradeRequest(action: "join", roomId: roomID))
    }
    public func enterOrRenewQueue(scope: String = "g:0:a:0", targetLegacyID: String? = nil) async throws -> TradingResponse {
        try await send(TradeRequest(action: "queue", scope: scope, targetLegacyId: targetLegacyID))
    }
    public func leaveQueue() async throws -> TradingResponse {
        try await send(TradeRequest(action: "leaveQueue"))
    }
    public func updateOffer(room: TradeRoom, offer: TradeOffer) async throws -> TradingResponse {
        try await send(TradeRequest(action: "offer", roomId: room.id, revision: room.revision, offer: offer))
    }
    public func ready(room: TradeRoom) async throws -> TradingResponse {
        try await send(TradeRequest(action: "ready", roomId: room.id, revision: room.revision))
    }
    public func confirm(room: TradeRoom) async throws -> TradingResponse {
        try await send(TradeRequest(action: "confirm", roomId: room.id, revision: room.revision))
    }
    public func nativeHandshake(roomID: String, payload: String) async throws -> TradingResponse {
        try await send(TradeRequest(action: "handshake", roomId: roomID, payload: payload))
    }
    public func sendSignal(roomID: String, type: String, payload: String) async throws -> TradingResponse {
        try await send(TradeRequest(action: "signal", roomId: roomID,
                                    signalType: type, signalPayload: payload))
    }
    public func setBotWishlist(roomID: String, cardIDs: [String]) async throws -> TradingResponse {
        try await send(TradeRequest(action: "botWishlist", roomId: roomID, cardIds: cardIDs))
    }
    public func setBotPeerHandshake(roomID: String, payload: String) async throws -> TradingResponse {
        try await send(TradeRequest(action: "botPeerHandshake", roomId: roomID, payload: payload))
    }
    public func cancel(roomID: String) async throws -> TradingResponse {
        try await send(TradeRequest(action: "cancel", roomId: roomID))
    }

    private func send(_ payload: TradeRequest) async throws -> TradingResponse {
        let startedGeneration = generation
        let credentials = try await sessionProvider()
        guard startedGeneration == generation else { throw TradingClientError.accountChanged }
        guard !credentials.uid.isEmpty, !credentials.idToken.isEmpty,
              !credentials.idToken.contains(where: { $0.isWhitespace }) else {
            throw TradingClientError.missingSession
        }
        if let uid = uid, uid != credentials.uid { throw TradingClientError.accountChanged }
        uid = credentials.uid
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await transport.send(request)
        guard startedGeneration == generation else { throw TradingClientError.accountChanged }
        guard data.count <= 1_048_576 else { throw TradingClientError.invalidResponse }
        let decoder = JSONDecoder()
        guard response.statusCode == 200 else {
            let code = (try? decoder.decode(ErrorResponse.self, from: data).error) ?? "HTTP_ERROR"
            throw TradingClientError.server(status: response.statusCode, code: code)
        }
        guard let result = try? decoder.decode(TradingResponse.self, from: data), result.ok else {
            throw TradingClientError.invalidResponse
        }
        return result
    }
}
