import Foundation
import MachO

struct RevivalFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Specific to the inspected, unencrypted arm64 FUT20 1.2 executable.
/// Every access happens on the main thread after the original game initialized storage.
@MainActor
final class LegacyInventoryBridge {
    private let slide: Int
    private let valet: NSObject
    private let cards: UnsafeMutablePointer<[String: Int]>
    private let get: @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
    private let put: @convention(c) (AnyObject, Selector, NSData, NSString) -> Bool

    init() throws {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else {
            throw RevivalFailure("Unsupported game executable.")
        }
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        var found = false
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.load(as: load_command.self)
            guard command.cmdsize >= 8 else { throw RevivalFailure("Invalid executable header.") }
            if command.cmd == LC_UUID {
                let bytes = Array(UnsafeRawBufferPointer(start: cursor.advanced(by: 8), count: 16))
                found = bytes == [0x9c,0x6e,0xd5,0x77,0x03,0x5a,0x36,0xd1,0xa0,0x4c,0x47,0x5a,0xcb,0x75,0x53,0xad]
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        guard found else { throw RevivalFailure("This game version has no supported collection adapter.") }
        slide = _dyld_get_image_vmaddr_slide(0)
        guard UnsafeRawPointer(bitPattern: 0x101268760 + slide)!.load(as: Int.self) == -1,
              let object = UnsafeRawPointer(bitPattern: 0x1012be658 + slide)!.load(as: UnsafeRawPointer?.self) else {
            throw RevivalFailure("The game is still loading. Open My Cards, then try Trading again.")
        }
        guard let storage = Unmanaged<AnyObject>.fromOpaque(object).takeUnretainedValue() as? NSObject,
              storage.isKind(of: NSClassFromString("VALValet") ?? NSObject.self),
              storage.responds(to: NSSelectorFromString("objectForKey:")),
              storage.responds(to: NSSelectorFromString("setObject:forKey:")) else {
            throw RevivalFailure("The original collection storage is unavailable.")
        }
        valet = storage
        cards = UnsafeMutablePointer<[String:Int]>(bitPattern: 0x1012be740 + slide)!
        get = unsafeBitCast(storage.method(for: NSSelectorFromString("objectForKey:")), to: (@convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?).self)
        put = unsafeBitCast(storage.method(for: NSSelectorFromString("setObject:forKey:")), to: (@convention(c) (AnyObject, Selector, NSData, NSString) -> Bool).self)
    }

    private func read(_ key: String) throws -> Any {
        guard let data = get(valet, NSSelectorFromString("objectForKey:"), key as NSString)?.takeUnretainedValue() as? Data,
              let value = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self, NSNumber.self], from: data) else {
            throw RevivalFailure("Cannot read the game's saved \(key). No collection was imported.")
        }
        return value
    }
    private func persisted() throws -> TradeInventory {
        guard let values = try read("myIds") as? [String:Int], let coins = try read("coins") as? Int else {
            throw RevivalFailure("Unexpected collection storage format.")
        }
        return try total(values, coins: coins)
    }
    private func total(_ duplicates: [String:Int], coins: Int) throws -> TradeInventory {
        guard (0...1_000_000_000).contains(coins), duplicates.count <= 30000,
              duplicates.allSatisfy({ !$0.key.isEmpty && (0..<1_000_000).contains($0.value) }) else {
            throw RevivalFailure("Collection values are outside the supported range.")
        }
        return TradeInventory(coins: coins, cards: duplicates.mapValues { $0 + 1 })
    }
    func snapshot() throws -> TradeInventory {
        let saved = try persisted()
        let live = try total(cards.pointee, coins: saved.coins)
        guard live == saved else { throw RevivalFailure("The game is saving its collection. Try again after it finishes.") }
        return saved
    }
    func apply(before: TradeInventory, after: TradeInventory) throws {
        let saved = try persisted()
        let live = try total(cards.pointee, coins: saved.coins)
        guard [before.cards, after.cards].contains(saved.cards), [before.cards, after.cards].contains(live.cards),
              [before.coins, after.coins].contains(saved.coins),
              after.cards.values.allSatisfy({ (1...1_000_000).contains($0) }),
              (0...1_000_000_000).contains(after.coins) else {
            throw RevivalFailure("The collection changed during settlement. Recovery paused to protect your save.")
        }
        let duplicates = after.cards.mapValues { $0 - 1 }
        let cardData = try NSKeyedArchiver.archivedData(withRootObject: duplicates, requiringSecureCoding: false)
        let coinData = try NSKeyedArchiver.archivedData(withRootObject: after.coins, requiringSecureCoding: false)
        guard put(valet, NSSelectorFromString("setObject:forKey:"), cardData as NSData, "myIds"),
              put(valet, NSSelectorFromString("setObject:forKey:"), coinData as NSData, "coins") else {
            throw RevivalFailure("Saving the trade failed. Reopen Trading to recover it; do not reinstall the app.")
        }
        cards.pointee = duplicates
        UserDefaults.standard.set(duplicates, forKey: "bXlJZHM=")
        UserDefaults.standard.set(after.coins, forKey: "Y29pbnM=")
        guard try snapshot() == after else { throw RevivalFailure("Saved collection verification failed.") }
    }
}

struct RevivalLedger: Codable {
    var uid: String
    var server: TradeInventory
    var version: Int
    var pendingBefore: TradeInventory?
    var pendingAfter: TradeInventory?
}

@MainActor
final class RevivalInventoryLedger {
    let bridge: LegacyInventoryBridge
    let file: URL
    var record: RevivalLedger?
    init(uid: String) throws {
        bridge = try LegacyInventoryBridge()
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        file = directory.appendingPathComponent("revival-trading-ledger.json")
        if FileManager.default.fileExists(atPath: file.path) {
            record = try JSONDecoder().decode(RevivalLedger.self, from: Data(contentsOf: file))
            guard record?.uid == uid else { throw RevivalFailure("This collection is linked to another trading account.") }
            if let before = record?.pendingBefore, let after = record?.pendingAfter {
                try bridge.apply(before: before, after: after)
                record?.pendingBefore = nil; record?.pendingAfter = nil
                try save()
            }
        }
    }
    func save() throws { try JSONEncoder().encode(record).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    func prepareImport(uid: String) throws -> TradeInventory {
        if let record = record { return record.server }
        let snapshot = try bridge.snapshot()
        record = RevivalLedger(uid: uid, server: snapshot, version: 1)
        try save()
        return snapshot
    }
    func reconcile(_ response: TradingResponse) throws {
        guard let server = response.inventory, let version = response.inventoryVersion, var old = record,
              response.preserveFirstCopy == true, version >= old.version else {
            throw RevivalFailure("This server collection is not compatible with this device. No save was changed.")
        }
        if server == old.server && version == old.version { return }
        guard version > old.version else { throw RevivalFailure("Server collection changed without a new revision.") }
        let before = try bridge.snapshot()
        var values = before.cards
        for key in Set(old.server.cards.keys).union(server.cards.keys) {
            let next = (values[key] ?? 0) + (server.cards[key] ?? 0) - (old.server.cards[key] ?? 0)
            guard (0...1_000_000).contains(next) else { throw RevivalFailure("Collection conflict. Trade recovery is paused.") }
            values[key] = next == 0 ? nil : next
        }
        let coins = before.coins + server.coins - old.server.coins
        guard (0...1_000_000_000).contains(coins) else { throw RevivalFailure("Coin balance conflict. Trade recovery is paused.") }
        let after = TradeInventory(coins: coins, cards: values)
        old.server = server; old.version = version; old.pendingBefore = before; old.pendingAfter = after
        record = old; try save()
        try bridge.apply(before: before, after: after)
        record?.pendingBefore = nil; record?.pendingAfter = nil; try save()
    }
}
