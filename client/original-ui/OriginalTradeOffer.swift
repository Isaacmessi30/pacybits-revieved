import Foundation

/// Keeps the original three positions, including gaps, across server snapshots.
public struct OriginalTradeOffer: Equatable {
    public private(set) var slots: [String?] = [nil, nil, nil]
    public private(set) var coins: Int = 0

    public init() {}

    public init(server offer: TradeOffer) throws {
        let positions = offer.slots ?? Array(offer.cards.indices)
        guard offer.cards.count <= 3, positions.count == offer.cards.count,
              Set(positions).count == positions.count,
              Set(offer.cards).count == offer.cards.count,
              offer.coins >= 0, offer.coins <= 1_000_000_000 else {
            throw TradingClientError.invalidResponse
        }
        for (index, card) in offer.cards.enumerated() {
            guard (0..<3).contains(positions[index]), !card.isEmpty else {
                throw TradingClientError.invalidResponse
            }
            slots[positions[index]] = card
        }
        coins = offer.coins
    }

    public var serverOffer: TradeOffer {
        let positions = slots.indices.filter { slots[$0] != nil }
        return TradeOffer(coins: coins, cards: positions.compactMap { slots[$0] }, slots: positions)
    }

    /// Returns false for confirmation and presentation events; those require the session adapter.
    @discardableResult
    public mutating func apply(_ action: OriginalTradeAction) throws -> Bool {
        switch action {
        case .picked(let slot, let card):
            guard (0..<3).contains(slot), !card.isEmpty,
                  !slots.enumerated().contains(where: { $0.offset != slot && $0.element == card }) else {
                throw TradingClientError.invalidResponse
            }
            slots[slot] = card
        case .deleted(let slot):
            guard (0..<3).contains(slot) else { throw TradingClientError.invalidResponse }
            slots[slot] = nil
        case .coins(let amount):
            guard (0...1_000_000_000).contains(amount) else { throw TradingClientError.invalidResponse }
            coins = amount
        default: return false
        }
        return true
    }
}
