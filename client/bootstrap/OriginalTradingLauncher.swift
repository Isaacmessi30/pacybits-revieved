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

    @objc static func prepareTrading(from presenter: UIViewController,
                                     completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            do {
                try await OriginalTradingCoordinator.ensureAuthenticated(from: presenter)
                completion(true)
            } catch {
                let alert = UIAlertController(title: "Trading", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                if presenter.presentedViewController == nil { presenter.present(alert, animated: true) }
                completion(false)
            }
        }
    }

    @objc static func beginScopedMatch(from presenter: UIViewController,
                                       scope: String,
                                       targetLegacyID: String?) {
        OriginalTradingCoordinator.beginOriginalMatch(
            from: presenter,
            scope: scope,
            targetLegacyID: targetLegacyID,
            localLegacyID: nil)
    }

    @objc static func isMatchActive() -> Bool {
        OriginalTradingCoordinator.hasActiveMatch
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
