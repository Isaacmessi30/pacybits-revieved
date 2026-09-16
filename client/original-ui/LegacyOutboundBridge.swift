import Foundation

/// The offline arm64 island calls this C entry point on the game's main thread.
/// The original sender owns the arguments: copy them before scheduling any work.
@MainActor
enum LegacyOutboundBridge {
    static var handle: ((String, Any?) -> Bool)?
}

@_cdecl("PBRLegacyOutbound")
@MainActor
func legacyOutbound(_ stringLow: UInt64, _ stringHigh: UInt64,
                    _ valueAddress: UnsafeRawPointer?) -> Int32 {
    guard Thread.isMainThread, let handle = LegacyOutboundBridge.handle,
          let valueAddress = valueAddress, MemoryLayout<String>.size == 16 else { return 0 }
    var words = (stringLow, stringHigh)
    let type: String = withUnsafePointer(to: &words) {
        UnsafeRawPointer($0).load(as: String.self)
    }
    guard type.hasPrefix("trading") else { return 0 }
    let value = valueAddress.load(as: Optional<Any>.self)
    return handle(type, value) ? 1 : 0
}
