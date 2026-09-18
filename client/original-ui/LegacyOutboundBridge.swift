import Foundation
import Darwin

private func probeNativeEvent(_ label: String) {
    guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "PBRNativeEventProbe") else { return }
    typealias Probe = @convention(c) (NSString) -> Void
    let function = unsafeBitCast(raw, to: Probe.self)
    function(label as NSString)
}

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
          MemoryLayout<String>.size == 16 else { return 0 }
    var words = (stringLow, stringHigh)
    let type: String = withUnsafePointer(to: &words) {
        UnsafeRawPointer($0).load(as: String.self)
    }
    let supportedPresentationEvent = type.hasPrefix("trading")
        || type == "emote"
        || type == "new_friend_info"
    guard supportedPresentationEvent else { return 0 }
    probeNativeEvent(type)
    let value: Any?
    if let valueAddress {
        value = valueAddress.load(as: Optional<Any>.self)
    } else {
        value = nil
    }
    return handle(type, value) ? 1 : 0
}
