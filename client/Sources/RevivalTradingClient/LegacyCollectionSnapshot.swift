import Foundation
import CoreFoundation

public enum LegacyCollectionError: Error, Equatable {
    case missingCollection
    case invalidCollection
    case invalidCardCount
}

/// Read-only interpretation of the inspected FUT20 v1.2 preferences format.
/// Static evidence supports the format; device-save validation is still required.
public struct LegacyCollectionSnapshot: Equatable, Sendable {
    public static let preferenceKey = Data("myIds".utf8).base64EncodedString()
    /// A present zero value means one retained collection card and no tradeable duplicates.
    public let duplicates: [String: Int]
    public var ownedCardIDs: Set<String> { Set(duplicates.keys) }
    public var tradeableCards: [String: Int] { duplicates.filter { $0.value > 0 } }

    public static func read(preferences: [String: Any]) throws -> Self {
        guard let stored = preferences[preferenceKey] else {
            throw LegacyCollectionError.missingCollection
        }
        guard let map = stored as? [String: Any], map.count <= 30_000 else {
            throw LegacyCollectionError.invalidCollection
        }
        var counts: [String: Int] = [:]
        for (id, value) in map {
            guard !id.isEmpty, let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue >= 0, number.doubleValue <= 1_000_000,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else {
                throw LegacyCollectionError.invalidCardCount
            }
            counts[id] = number.intValue
        }
        return Self(duplicates: counts)
    }
}
