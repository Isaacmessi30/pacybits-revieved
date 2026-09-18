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
protocol OriginalInventoryAccess {
    func snapshot() throws -> TradeInventory
    func apply(before: TradeInventory, after: TradeInventory) throws
}

@MainActor
final class LegacyInventoryBridge: OriginalInventoryAccess {
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
        let imageSlide = _dyld_get_image_vmaddr_slide(0)
        slide = imageSlide
        // Invoke the original lazy global accessors instead of requiring that
        // another screen happened to initialize these globals first.
        func originalGlobal(entry: Int, prefix: [UInt8], expected: Int) throws -> UnsafeMutableRawPointer {
            let address = UnsafeRawPointer(bitPattern: entry + imageSlide)!
            guard Array(UnsafeRawBufferPointer(start: address, count: prefix.count)) == prefix else {
                throw RevivalFailure("Collection adapter C03: unsupported storage accessor.")
            }
            let accessor = unsafeBitCast(address, to: (@convention(thin) () -> UnsafeMutableRawPointer).self)
            let result = accessor()
            guard result == UnsafeMutableRawPointer(bitPattern: expected + imageSlide) else {
                throw RevivalFailure("Collection adapter C03: unexpected storage location.")
            }
            return result
        }
        let storageSlot = try originalGlobal(entry: 0x100199d44,
            prefix: [0x68,0x86,0x00,0xf0,0x08,0x45,0x43,0xf9,0x1f,0x05,0x00,0xb1,0x20,0x01,0x00,0x54],
            expected: 0x1012be658)
        guard let object = storageSlot.load(as: UnsafeRawPointer?.self) else {
            throw RevivalFailure("Collection adapter C02: the original saved-collection storage is unavailable. Report C02; your Google login is still saved.")
        }
        let cardSlot = try originalGlobal(entry: 0x10022cafc,
            prefix: [0xe8,0x81,0x00,0x90,0x08,0xb1,0x43,0xf9,0x1f,0x05,0x00,0xb1,0x20,0x01,0x00,0x54],
            expected: 0x1012be740)
        guard cardSlot.load(as: UnsafeRawPointer?.self) != nil else {
            throw RevivalFailure("Collection adapter C01: the original card dictionary is unavailable after initialization.")
        }
        guard let storage = Unmanaged<AnyObject>.fromOpaque(object).takeUnretainedValue() as? NSObject,
              let expectedClass = NSClassFromString("VALValet"), storage.isKind(of: expectedClass),
              storage.responds(to: NSSelectorFromString("objectForKey:")),
              storage.responds(to: NSSelectorFromString("setObject:forKey:")) else {
            throw RevivalFailure("The original collection storage is unavailable.")
        }
        valet = storage
        cards = cardSlot.assumingMemoryBound(to: [String:Int].self)
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
    let bridge: OriginalInventoryAccess
    let file: URL
    var record: RevivalLedger?
    init(uid: String, bridge: OriginalInventoryAccess? = nil, file: URL? = nil) throws {
        self.bridge = try bridge ?? LegacyInventoryBridge()
        if let file = file { self.file = file }
        else {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            self.file = directory.appendingPathComponent("revival-trading-ledger.json")
        }
        if FileManager.default.fileExists(atPath: self.file.path) {
            record = try JSONDecoder().decode(RevivalLedger.self, from: Data(contentsOf: self.file))
            guard record?.uid == uid else { throw RevivalFailure("This collection is linked to another trading account.") }
            if let before = record?.pendingBefore, let after = record?.pendingAfter {
                try self.bridge.apply(before: before, after: after)
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
        do { try save() }
        catch { record = nil; throw error }
        return snapshot
    }

    /// Recreates the local ledger after an app reinstall/update removed
    /// Application Support while Firebase credentials survived in Keychain.
    /// Recovery is allowed only when the authenticated server collection exactly
    /// matches PACYBITS' current persisted collection, so no cards or coins are
    /// imported, overwritten or duplicated during the re-anchor.
    func localSnapshot() throws -> TradeInventory { try bridge.snapshot() }

    func attachServerBaseline(uid: String, response: TradingResponse) throws {
        guard record == nil,
              response.ok,
              response.inventoryReady == true,
              let server = response.inventory,
              let version = response.inventoryVersion,
              version > 0,
              response.preserveFirstCopy == true else {
            throw RevivalFailure("The saved trading collection cannot be attached safely.")
        }
        record = RevivalLedger(uid: uid, server: server, version: version)
        do { try save() }
        catch { record = nil; throw error }
    }

    func recoverAfterReinstall(uid: String, response: TradingResponse) throws {
        guard let server = response.inventory else {
            throw RevivalFailure("The saved trading collection cannot be recovered safely.")
        }
        let local = try bridge.snapshot()
        guard local == server else {
            throw RevivalFailure("Your PACYBITS collection and the saved trading collection are different. No cards or coins were changed.")
        }
        try attachServerBaseline(uid: uid, response: response)
    }

    func restoreServerCollection(uid: String, response: TradingResponse) throws {
        guard record == nil,
              response.ok,
              response.inventoryReady == true,
              let server = response.inventory,
              let version = response.inventoryVersion,
              version > 0,
              response.preserveFirstCopy == true else {
            throw RevivalFailure("The saved trading collection cannot be restored safely.")
        }
        let before = try bridge.snapshot()
        if before != server { try bridge.apply(before: before, after: server) }
        guard try bridge.snapshot() == server else {
            throw RevivalFailure("PACYBITS did not save the restored trading collection.")
        }
        record = RevivalLedger(uid: uid, server: server, version: version)
        do { try save() }
        catch { record = nil; throw error }
    }
    func reconcile(_ response: TradingResponse) throws {
        if let before = record?.pendingBefore, let after = record?.pendingAfter {
            try bridge.apply(before: before, after: after)
            try finishNativeSettlement()
        }
        guard try stageSettlement(response) else { return }
        guard let before = record?.pendingBefore, let after = record?.pendingAfter else {
            throw RevivalFailure("Trade recovery record is incomplete.")
        }
        try bridge.apply(before: before, after: after)
        try finishNativeSettlement()
    }

    /// Persist the expected change before allowing the ORIGINAL completion routine
    /// to update the collection. False means this receipt was already accounted for;
    /// callers must not run the original transfer again in that case.
    func prepareNativeSettlement(_ response: TradingResponse) throws -> Bool {
        guard response.room?.isCompleted == true, let version = response.inventoryVersion,
              let old = record, old.version > 0, old.version < Int.max,
              version == old.version || version == old.version + 1 else {
            throw RevivalFailure("The native trade requires its current, completed server receipt.")
        }
        return try stageSettlement(response)
    }

    private func stageSettlement(_ response: TradingResponse) throws -> Bool {
        guard record?.pendingBefore == nil, record?.pendingAfter == nil else {
            throw RevivalFailure("A previous trade is awaiting save verification.")
        }
        guard response.ok, let server = response.inventory, let version = response.inventoryVersion, var old = record,
              response.preserveFirstCopy == true, version >= old.version else {
            throw RevivalFailure("This server collection is not compatible with this device. No save was changed.")
        }
        func valid(_ inventory: TradeInventory) -> Bool {
            (0...1_000_000_000).contains(inventory.coins) && inventory.cards.count <= 30000 &&
            inventory.cards.allSatisfy { !$0.key.isEmpty && (1...1_000_000).contains($0.value) }
        }
        guard valid(server), valid(old.server) else {
            throw RevivalFailure("Invalid server collection. No save was changed.")
        }
        if server == old.server && version == old.version { return false }
        guard version > old.version else { throw RevivalFailure("Server collection changed without a new revision.") }
        let before = try bridge.snapshot()
        guard valid(before) else { throw RevivalFailure("Invalid local collection. No save was changed.") }
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
        let previous = record
        record = old
        do { try save() }
        catch { record = previous; throw error }
        return true
    }

    /// Observe the native save; this method never applies the transfer a second time.
    func finishNativeSettlement() throws {
        guard let expected = record?.pendingAfter, record?.pendingBefore != nil,
              try bridge.snapshot() == expected else {
            throw RevivalFailure("The original game save does not match the confirmed trade. Recovery is paused.")
        }
        let previous = record
        record?.pendingBefore = nil; record?.pendingAfter = nil
        do { try save() }
        catch { record = previous; throw error }
    }
}
