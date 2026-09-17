import UIKit

@MainActor
@objc(PBROriginalTradingLauncher)
final class OriginalTradingLauncher: NSObject {
    /// Legacy entry point retained for older test builds. The live original-menu
    /// flow no longer calls this because PACYBITS owns its own menu/dialog UI.
    @objc static func open(from presenter: UIViewController, mode: String) {
        let selected: OriginalTradingCoordinator.Mode
        switch mode.lowercased() {
        case "code": selected = .code
        case "friends": selected = .friends
        case "channels": selected = .channels
        default: selected = .random
        }
        OriginalTradingCoordinator.open(from: presenter, mode: selected)
    }

    @objc static func beginOriginalMatch(from presenter: UIViewController,
                                         scope: String,
                                         targetLegacyID: String?,
                                         localLegacyID: String?) {
        OriginalTradingCoordinator.beginOriginalMatch(
            from: presenter,
            scope: scope,
            targetLegacyID: targetLegacyID,
            localLegacyID: localLegacyID)
    }

    @objc static func cancelOriginalMatch() {
        OriginalTradingCoordinator.cancelActiveMatch()
    }
}
