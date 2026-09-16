import Foundation
@main struct Check {
    @MainActor static func main() {
        var captured: (String, Any?)?
        LegacyOutboundBridge.handle = { type, value in captured = (type, value); return true }
        for type in ["tradingReady", "tradingPickedOutline" + String(repeating: "X", count: 100)] {
            var name = type
            var value: Any? = ["tag": 2, "player": String(repeating: "player", count: 40)] as [String:Any]
            let result = withUnsafePointer(to: &name) { name in
                let bits = UnsafeRawPointer(name).load(as: (UInt64, UInt64).self)
                return withUnsafePointer(to: &value) { legacyOutbound(bits.0, bits.1, $0) }
            }
            precondition(result == 1 && captured?.0 == type)
            value = nil
            precondition((captured?.1 as? [String:Any])?["tag"] as? Int == 2)
        }
        captured = nil
        var other = "draftMessage"
        var empty: Any? = nil
        let fallback = withUnsafePointer(to: &other) { name in
            let bits = UnsafeRawPointer(name).load(as: (UInt64, UInt64).self)
            return withUnsafePointer(to: &empty) { legacyOutbound(bits.0, bits.1, $0) }
        }
        precondition(fallback == 0 && captured == nil)
        LegacyOutboundBridge.handle = nil
        precondition(legacyOutbound(0, 0, nil) == 0)
        print("Borrowed short/heap String and Any payload copies retained successfully")
    }
}
