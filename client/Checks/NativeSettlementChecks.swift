import Foundation

private enum Failure: Error { case failed(String) }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.failed(message) }
}
private func rejects(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw Failure.failed("Expected rejection")
}
@MainActor private final class Inventory: OriginalInventoryAccess {
    var value = TradeInventory(coins: 100, cards: ["a": 3])
    var writes = 0
    func snapshot() throws -> TradeInventory { value }
    func apply(before: TradeInventory, after: TradeInventory) throws {
        try check(value == before || value == after, "Recovery must recognize saved state")
        value = after
        writes += 1
    }
}
@main struct NativeSettlementChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func receipt(coins: Int = 90, version: Int = 2) throws -> TradingResponse {
            let body: [String:Any] = ["ok": true, "preserveFirstCopy": true,
                "inventoryVersion": version, "inventory": ["coins": coins, "cards": ["a": 2, "b": 1]],
                "room": ["id": "r", "status": "completed", "expiresAt": 1, "revision": 2,
                    "self": "alice", "members": ["alice", "bob"], "offers": [:], "ready": [:], "confirmed": [:]]]
            return try JSONDecoder().decode(TradingResponse.self, from: JSONSerialization.data(withJSONObject: body))
        }
        func fresh(_ name: String) throws -> (RevivalInventoryLedger, Inventory, URL) {
            let inventory = Inventory()
            let file = directory.appendingPathComponent(name)
            let ledger = try RevivalInventoryLedger(uid: "alice", bridge: inventory, file: file)
            _ = try ledger.prepareImport(uid: "alice")
            return (ledger, inventory, file)
        }
        let response = try receipt()
        let expected = TradeInventory(coins: 90, cards: ["a": 2, "b": 1])
        let (ledger, inventory, file) = try fresh("normal")
        try check(try ledger.prepareNativeSettlement(response), "New receipt must stage")
        let persisted = try JSONDecoder().decode(RevivalLedger.self, from: Data(contentsOf: file))
        try check(persisted.pendingAfter == expected && inventory.writes == 0, "Journal must precede native write")
        try rejects { try ledger.finishNativeSettlement() }
        try check(ledger.record?.pendingAfter == expected, "Mismatch must preserve recovery journal")
        inventory.value = expected // Simulate the original game's completion routine.
        try ledger.finishNativeSettlement()
        try check(inventory.writes == 0, "Verification must not apply a second transfer")
        try check(try !ledger.prepareNativeSettlement(response), "Repeated receipt must not run completion")
        print("PASS native save is journaled, verified, and not applied twice")

        let (interrupted, interruptedInventory, interruptedFile) = try fresh("interrupted")
        _ = try interrupted.prepareNativeSettlement(response)
        let recovered = try RevivalInventoryLedger(uid: "alice", bridge: interruptedInventory, file: interruptedFile)
        try check(interruptedInventory.value == expected && interruptedInventory.writes == 1 && recovered.record?.pendingAfter == nil, "Interrupted save must recover")
        _ = try RevivalInventoryLedger(uid: "alice", bridge: interruptedInventory, file: interruptedFile)
        try check(interruptedInventory.writes == 1, "Recovery must not repeat after restart")
        print("PASS interrupted native save recovers once")

        let (invalid, untouched, _) = try fresh("invalid")
        try rejects { _ = try invalid.prepareNativeSettlement(receipt(coins: Int.max)) }
        try rejects { _ = try invalid.prepareNativeSettlement(receipt(version: 4)) }
        try check(untouched.writes == 0 && invalid.record?.version == 1, "Invalid receipt must leave baseline intact")
        print("PASS invalid or skipped receipts leave the save intact")

        let (failed, unchanged, failedFile) = try fresh("failed")
        try FileManager.default.removeItem(at: failedFile)
        try FileManager.default.createDirectory(at: failedFile, withIntermediateDirectories: false)
        try rejects { _ = try failed.prepareNativeSettlement(response) }
        try check(failed.record?.version == 1 && failed.record?.pendingAfter == nil && unchanged.writes == 0, "Failed journal must roll back memory")
        print("PASS failed journal cannot advance settlement")
    }
}
