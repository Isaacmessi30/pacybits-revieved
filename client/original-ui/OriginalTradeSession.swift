import Foundation

/// Serializes the original screen's actions against the server's room revision.
/// Returned snapshots must be rendered by the native adapter. This class never
/// runs the game's handshake or writes a collection.
@MainActor
final class OriginalTradeSession {
    private enum Operation { case action(OriginalTradeAction), refresh, cancel }
    private let api: TradingClient
    private let roomID: String
    private let selfKey: String
    private let validateOffer: (TradeOffer) throws -> Void
    private var snapshot: TradingResponse
    private var tail: Task<TradingResponse, Error>?
    private var needsRefresh = false

    init(api: TradingClient, initial: TradingResponse,
         validateOffer: @escaping (TradeOffer) throws -> Void) throws {
        guard let room = initial.room, room.status == "open", room.members.count == 2,
              Set(room.members).count == 2, room.members.contains(room.selfKey),
              let offer = room.offers[room.selfKey] else { throw TradingClientError.invalidResponse }
        _ = try OriginalTradeOffer(server: offer)
        self.api = api
        roomID = room.id
        selfKey = room.selfKey
        snapshot = initial
        self.validateOffer = validateOffer
    }

    func submit(_ action: OriginalTradeAction) async throws -> TradingResponse {
        try await enqueue(.action(action))
    }
    func refresh() async throws -> TradingResponse { try await enqueue(.refresh) }
    func cancel() async throws -> TradingResponse { try await enqueue(.cancel) }

    private func enqueue(_ operation: Operation) async throws -> TradingResponse {
        let previous = tail
        let task = Task { @MainActor in
            if let previous = previous { _ = try? await previous.value }
            return try await self.execute(operation)
        }
        tail = task
        return try await task.value
    }

    private func execute(_ operation: Operation) async throws -> TradingResponse {
        guard let room = snapshot.room else { throw TradingClientError.invalidResponse }
        do {
            var result: TradingResponse
            switch operation {
            case .refresh:
                result = try await api.status(roomID: roomID)
            case .cancel:
                result = try await api.cancel(roomID: roomID)
            case .action(let action):
                guard !needsRefresh else { throw TradingClientError.invalidResponse }
                // A native handshake cannot authorize a server transfer. The caller
                // must wait for a completed snapshot and coordinate local settlement.
                if action == .handshake { return snapshot }
                guard room.status == "open", let current = room.offers[selfKey] else {
                    throw TradingClientError.invalidResponse
                }
                var draft = try OriginalTradeOffer(server: current)
                if try draft.apply(action) {
                    try validateOffer(draft.serverOffer)
                    result = try await api.updateOffer(room: room, offer: draft.serverOffer)
                } else {
                    switch action {
                    case .ready:
                        try validateOffer(current)
                        result = try await api.ready(room: room)
                    case .accept:
                        try validateOffer(current)
                        result = try await api.confirm(room: room)
                    case .makeChanges, .cancelAcceptance:
                        // Re-submitting the same offer invalidates both confirmations.
                        try validateOffer(current)
                        result = try await api.updateOffer(room: room, offer: current)
                    default: throw TradingClientError.invalidResponse
                    }
                }
            }
            if result.room?.isCompleted == true && result.inventory == nil {
                // Confirmation returns a room, not the authoritative inventory.
                // Fetch the receipt before any caller can reconcile the local save.
                result = try await api.status(roomID: roomID)
                guard result.room?.isCompleted == true, result.inventory != nil,
                      (result.inventoryVersion ?? 0) > 0 else { throw TradingClientError.invalidResponse }
            }
            if result.room?.isCompleted == true {
                guard result.inventory != nil, (result.inventoryVersion ?? 0) > 0 else {
                    throw TradingClientError.invalidResponse
                }
            }
            guard let updated = result.room, updated.id == roomID, updated.selfKey == selfKey,
                  updated.revision >= room.revision, updated.members == room.members,
                  ["open", "completed", "cancelled", "expired"].contains(updated.status),
                  updated.offers[selfKey] != nil,
                  room.status == "open" || updated.status == room.status else {
                throw TradingClientError.invalidResponse
            }
            for member in updated.members {
                guard let offer = updated.offers[member] else { throw TradingClientError.invalidResponse }
                _ = try OriginalTradeOffer(server: offer)
            }
            snapshot = result
            needsRefresh = false
            return result
        } catch {
            // The server may have committed before a connection failed. Never replay
            // the mutation automatically or use its old revision for the next action.
            needsRefresh = true
            throw error
        }
    }
}
