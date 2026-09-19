import UIKit
import MachO

/// Uses the existing storyboard and native receiver; owns no replacement layout.
/// The session coordinator must install transport before presenting this screen.
@MainActor
final class OriginalTradingScreen {
    let controller: UIViewController
    private let slide: Int
    private let helper: NSObject
    private let profile: UnsafeMutablePointer<[String:Any]>
    private let previousProfile: [String:Any]
    private var restored = false
    private let receive: @convention(thin) (String, [String:Any]) -> Void

    init(peerClubName: String, badgeName: String = "pacybits_fc_logo_large.png",
         existingController: UIViewController? = nil,
         updateProfile: Bool = true) throws {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else {
            throw RevivalFailure("Unsupported game executable.")
        }
        let base = UnsafeRawPointer(header)
        let headerSize = MemoryLayout<mach_header_64>.size
        let end = headerSize + Int(header.pointee.sizeofcmds)
        var offset = headerSize
        var matched = false
        for _ in 0..<header.pointee.ncmds {
            guard offset + 8 <= end else { throw RevivalFailure("Invalid executable header.") }
            let command = base.advanced(by: offset).load(as: load_command.self)
            guard command.cmdsize >= 8, offset + Int(command.cmdsize) <= end else {
                throw RevivalFailure("Invalid executable header.")
            }
            if command.cmd == LC_UUID && command.cmdsize >= 24 {
                let bytes = Array(UnsafeRawBufferPointer(start: base.advanced(by: offset + 8), count: 16))
                matched = bytes == [0x9c,0x6e,0xd5,0x77,0x03,0x5a,0x36,0xd1,0xa0,0x4c,0x47,0x5a,0xcb,0x75,0x53,0xad]
            }
            offset += Int(command.cmdsize)
        }
        guard matched, offset == end else { throw RevivalFailure("Unsupported original trading screen version.") }
        slide = _dyld_get_image_vmaddr_slide(0)
        let entry = UnsafeRawPointer(bitPattern: 0x1006e48b4 + slide)!
        guard Array(UnsafeRawBufferPointer(start: entry, count: 16)) ==
                [0xff,0x43,0x04,0xd1,0xfc,0x6f,0x0b,0xa9,0xfa,0x67,0x0c,0xa9,0xf8,0x5f,0x0d,0xa9],
              let pointer = UnsafeRawPointer(bitPattern: 0x1012be350 + slide)!.load(as: UnsafeRawPointer?.self),
              let expected = NSClassFromString("_TtC13PACYBITSFUT2016GameCenterHelper"),
              let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? NSObject,
              object.isKind(of: expected) else {
            throw RevivalFailure("The original trading engine is not initialized.")
        }
        helper = object
        let field = UnsafeRawPointer(bitPattern: 0x101297318 + slide)!.load(as: Int.self)
        guard field >= 16, field < 4096, field % 8 == 0 else {
            throw RevivalFailure("Unexpected opponent profile layout.")
        }
        profile = UnsafeMutableRawPointer(mutating: pointer).advanced(by: field).assumingMemoryBound(to: [String:Any].self)
        previousProfile = profile.pointee
        if let existingController {
            controller = existingController
        } else {
            guard let native = PBRInstantiateOriginalTrading() else {
                throw RevivalFailure("The original Trading storyboard could not be loaded.")
            }
            controller = native
        }
        receive = unsafeBitCast(entry, to: (@convention(thin) (String, [String:Any]) -> Void).self)
        if updateProfile {
            profile.pointee = ["clubName": String(peerClubName.prefix(40)), "badgeName": badgeName]
        }
    }

    static func attachCurrent(peerClubName: String,
                              badgeName: String = "pacybits_fc_logo_large.png") throws -> OriginalTradingScreen? {
        guard let controller = PBRCurrentOriginalTrading() else { return nil }
        return try OriginalTradingScreen(peerClubName: peerClubName,
                                         badgeName: badgeName,
                                         existingController: controller,
                                         updateProfile: false)
    }

    /// Feeds the same peer intro event PACYBITS expects after Game Center
    /// matchmaking. The receiver stores opponentInfo and advances the original
    /// trading/navigation state; manually setting the profile dictionary alone
    /// is not equivalent.
    static func primeTradingIntro(peerClubName: String,
                                  badgeName: String = "pacybits_fc_logo_large.png") throws {
        let slide = _dyld_get_image_vmaddr_slide(0)
        guard let entry = UnsafeRawPointer(bitPattern: 0x1006e48b4 + slide),
              Array(UnsafeRawBufferPointer(start: entry, count: 16)) ==
                [0xff,0x43,0x04,0xd1,0xfc,0x6f,0x0b,0xa9,0xfa,0x67,0x0c,0xa9,0xf8,0x5f,0x0d,0xa9] else {
            throw RevivalFailure("Unsupported original trading receiver.")
        }
        let receive = unsafeBitCast(
            entry, to: (@convention(thin) (String, [String:Any]) -> Void).self)
        let opponent: [String:Any] = [
            "clubName": String(peerClubName.prefix(40)),
            "badgeName": badgeName
        ]
        receive("tradingIntro", ["value": opponent])
    }

    /// Uses PACYBITS' own app navigation routine. This is the same function the
    /// empty trading-card slot uses with route "duplicates"; entering trading
    /// through route "trading" keeps the controller inside the original
    /// tab/navigation hierarchy instead of presenting it modally.
    static func openOriginalRoute(_ route: String) throws {
        guard ["trading", "duplicates"].contains(route) else {
            throw RevivalFailure("Unsupported PACYBITS route.")
        }
        let slide = _dyld_get_image_vmaddr_slide(0)
        guard let entry = UnsafeRawPointer(bitPattern: 0x1002bd8fc + slide) else {
            throw RevivalFailure("Unsupported PACYBITS navigation routine.")
        }
        typealias NativeRoute = @convention(thin) (String, Bool, Bool, Bool) -> Void
        let navigate = unsafeBitCast(entry, to: NativeRoute.self)
        navigate(route, false, false, false)
    }

    static func openOriginalTradingRoute() throws {
        try openOriginalRoute("trading")
    }


    static func deliverPretradeSignal(_ signal: TradeSignal) throws {
        guard ["new_friend_info", "tradingIntro"].contains(signal.type),
              signal.payload.count <= 12_000,
              let data = Data(base64Encoded: signal.payload),
              data.count <= 8_192,
              let box = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String:Any] else {
            throw RevivalFailure("Invalid PACYBITS pre-trade event.")
        }
        let slide = _dyld_get_image_vmaddr_slide(0)
        guard let entry = UnsafeRawPointer(bitPattern: 0x1006e48b4 + slide),
              Array(UnsafeRawBufferPointer(start: entry, count: 16)) ==
                [0xff,0x43,0x04,0xd1,0xfc,0x6f,0x0b,0xa9,0xfa,0x67,0x0c,0xa9,0xf8,0x5f,0x0d,0xa9] else {
            throw RevivalFailure("Unsupported original trading receiver.")
        }
        let receive = unsafeBitCast(
            entry, to: (@convention(thin) (String, [String:Any]) -> Void).self)
        let value: Any = box["nil"] as? Bool == true ? "" : (box["value"] ?? "")
        receive(signal.type, ["value": value])
    }

    func restoreProfile() {
        guard !restored else { return }
        profile.pointee = previousProfile
        restored = true
    }

    var isActive: Bool {
        guard !restored, LegacyOutboundBridge.handle != nil,
              UIApplication.shared.applicationState == .active,
              controller.isViewLoaded, controller.view.window != nil,
              let expected = NSClassFromString("_TtC13PACYBITSFUT2021TradingViewController"),
              controller.isKind(of: expected) else {
            return false
        }
        return true
    }

    private func requireActive() throws {
        guard isActive else {
            throw RevivalFailure("The original trading screen is not active.")
        }
    }

    func renderSignal(_ signal: TradeSignal) throws {
        try requireActive()
        guard signal.payload.count <= 12_000, let data = Data(base64Encoded: signal.payload),
              data.count <= 8_192,
              let box = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String:Any] else {
            throw RevivalFailure("Invalid PACYBITS presentation event.")
        }
        let value: Any = box["nil"] as? Bool == true ? "" : (box["value"] ?? "")
        if signal.type == "tradingMessage", let text = value as? String {
            if let label = controller.value(forKey: "messageRight") as? UILabel {
                label.text = text
                label.alpha = 1.0
                return
            }
        }
        receive(signal.type, ["value": value])
    }

    func renderWishlist(_ ids: [String]) throws {
        try requireActive()
        var players: [Any] = []
        var seen = Set<String>()
        for id in ids.prefix(50) where !seen.contains(id) {
            guard let player = PBRPlayerForIdentifier(id) else { continue }
            seen.insert(id)
            players.append(player)
        }
        receive("tradingDidSetWishlist", ["value": players])
    }

    func render(_ actions: [OriginalTradeAction]) throws {
        try requireActive()
        var messages: [(String, Any)] = []
        for action in actions {
            switch action {
            case .picked(let slot, let id):
                guard (0..<3).contains(slot), let player = PBRPlayerForIdentifier(id) else {
                    throw RevivalFailure("A traded card is missing from this game's catalog.")
                }
                messages.append(("tradingPickedOutline", ["tag": slot, "player": player] as [String:Any]))
            case .deleted(let slot):
                guard (0..<3).contains(slot) else { throw TradingClientError.invalidResponse }
                messages.append(("tradingDeletedOutline", slot))
            case .coins(let amount):
                guard (0...1_000_000_000).contains(amount) else { throw TradingClientError.invalidResponse }
                messages.append(("tradingCoins", amount))
            case .ready: messages.append(("tradingReady", ""))
            case .makeChanges: messages.append(("tradingMakeChanges", ""))
            case .accept: messages.append(("tradingCompleteTradeAccept", ""))
            case .cancelAcceptance: messages.append(("tradingCompleteTradeCancel", ""))
            case .handshake:
                throw RevivalFailure("Native completion requires a reconciled server receipt.")
            }
        }
        for (type, value) in messages { receive(type, ["value": value]) }
    }

    /// Invoked only after the server has completed the room and the ledger has
    /// staged the exact expected local collection change.
    func renderHandshake(_ value: [String:Any]) throws {
        try requireActive()
        guard Set(value.keys) == Set(["coins", "idsLeft", "idsRight"]) else {
            throw RevivalFailure("Invalid native completion payload.")
        }
        receive("tradingHandshake", ["value": value])
    }
}
