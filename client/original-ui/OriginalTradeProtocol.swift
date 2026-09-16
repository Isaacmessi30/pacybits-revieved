import Foundation
import CoreFoundation

/// Only message payloads established from the inspected native dispatch routines.
/// Presentation remains owned by the original Trading.storyboard and game classes.
public enum OriginalTradeAction: Equatable {
    case picked(slot: Int, cardID: String)
    case deleted(slot: Int)
    case coins(Int)
    case ready
    case makeChanges
    case accept
    case cancelAcceptance
    case handshake
}

public enum OriginalTradeProtocol {
    public static func decode(type: String, value: Any?, playerID: (Any) -> String?) throws -> OriginalTradeAction {
        switch type {
        case "tradingPickedOutline":
            guard let dictionary = value as? [String:Any],
                  let slot = integer(dictionary["tag"], maximum: 2),
                  let player = dictionary["player"], let id = playerID(player),
                  !id.isEmpty else { throw FirebaseAuthenticationError.invalidResponse }
            return .picked(slot: slot, cardID: id)
        case "tradingDeletedOutline":
            guard let slot = integer(value, maximum: 2) else { throw FirebaseAuthenticationError.invalidResponse }
            return .deleted(slot: slot)
        case "tradingCoins":
            guard let amount = integer(value, maximum: 1_000_000_000) else { throw FirebaseAuthenticationError.invalidResponse }
            return .coins(amount)
        case "tradingReady": return .ready
        case "tradingMakeChanges": return .makeChanges
        case "tradingCompleteTradeAccept": return .accept
        case "tradingCompleteTradeCancel": return .cancelAcceptance
        case "tradingHandshake": return .handshake
        default: throw FirebaseAuthenticationError.invalidResponse
        }
    }
    private static func integer(_ value: Any?, maximum: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue <= Double(maximum) else { return nil }
        return number.intValue
    }
}
