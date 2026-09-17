import Foundation

/// Produces native presentation events from authenticated server snapshots.
/// Handshake/completion is intentionally a separate receipt-controlled operation.
struct OriginalTradePeerState: Equatable {
    let roomID: String
    let peer: String
    let revision: Int
    let offer: OriginalTradeOffer
    let ready: Bool
    let accepted: Bool
    let status: String

    init(room: TradeRoom) throws {
        guard room.members.count == 2, Set(room.members).count == 2,
              room.members.contains(room.selfKey),
              let peer = room.members.first(where: { $0 != room.selfKey }),
              let offer = room.offers[peer], room.revision >= 0,
              ["open", "completed", "cancelled", "expired"].contains(room.status) else {
            throw TradingClientError.invalidResponse
        }
        roomID = room.id
        self.peer = peer
        revision = room.revision
        self.offer = try OriginalTradeOffer(server: offer)
        ready = room.ready[peer] == room.revision
        accepted = room.confirmed[peer] == room.revision
        guard !accepted || ready else { throw TradingClientError.invalidResponse }
        status = room.status
    }

    func events(after previous: OriginalTradePeerState?) throws -> [OriginalTradeAction] {
        if let previous = previous {
            guard previous.roomID == roomID, previous.peer == peer,
                  previous.revision <= revision,
                  previous.status == "open" || previous == self,
                  previous.revision != revision || previous.offer == offer else {
                throw TradingClientError.invalidResponse
            }
        }
        // The lifecycle adapter handles these terminal states, not the card renderer.
        guard status == "open" || status == "completed" else { return [] }
        let oldOffer = previous?.offer ?? OriginalTradeOffer()
        let revisionChanged = previous.map { $0.revision != revision } ?? false
        var events: [OriginalTradeAction] = []
        if let previous = previous, (previous.ready || previous.accepted),
           revisionChanged || !ready || (previous.accepted && !accepted) {
            events.append(.makeChanges)
        }
        // Clear changed positions before filling them so a swap never briefly
        // displays the same card in two positions or deletes a newly placed card.
        for slot in 0..<3 where oldOffer.slots[slot] != offer.slots[slot] && oldOffer.slots[slot] != nil {
            events.append(.deleted(slot: slot))
        }
        for slot in 0..<3 where oldOffer.slots[slot] != offer.slots[slot] {
            if let card = offer.slots[slot] { events.append(.picked(slot: slot, cardID: card)) }
        }
        if oldOffer.coins != offer.coins { events.append(.coins(offer.coins)) }
        if ready && (previous?.ready != true || revisionChanged) { events.append(.ready) }
        if accepted && (previous?.accepted != true || revisionChanged) { events.append(.accept) }
        return events
    }
}
