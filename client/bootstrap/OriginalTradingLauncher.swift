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


@_cdecl("PBRBeginRandomTradingDirect")
func PBRBeginRandomTradingDirect(_ presenterOpaque: UnsafeMutableRawPointer?) -> Bool {
    guard let presenterOpaque else { return false }
    let presenter = Unmanaged<UIViewController>.fromOpaque(presenterOpaque).takeUnretainedValue()
    Task { @MainActor in
        OriginalTradingCoordinator.beginOriginalMatch(
            from: presenter,
            scope: "g:0:a:0",
            targetLegacyID: nil,
            localLegacyID: nil)
    }
    return true
}


@MainActor
@objc(PBRAccountManager)
final class RevivalAccountManager: NSObject {
    @objc(signInOrSwitchFrom:)
    static func signInOrSwitch(from presenter: UIViewController) {
        Task { @MainActor in
            do {
                OriginalTradingCoordinator.cancelActiveMatch()
                let (config, auth) = try authentication()
                _ = try await GoogleBrowserLogin(configuration: config, authentication: auth)
                    .signIn(presenting: presenter)
                presentResult(on: presenter, title: "Google Account",
                              message: "Signed in successfully. Trading will use this Google account.")
            } catch {
                presentResult(on: presenter, title: "Google Account",
                              message: error.localizedDescription)
            }
        }
    }

    @objc(signOutFrom:)
    static func signOut(from presenter: UIViewController) {
        Task { @MainActor in
            do {
                OriginalTradingCoordinator.cancelActiveMatch()
                let (_, auth) = try authentication()
                try await auth.signOut()
                presentResult(on: presenter, title: "Google Account",
                              message: "Signed out. You can sign in with another Google account at any time.")
            } catch {
                presentResult(on: presenter, title: "Google Account",
                              message: error.localizedDescription)
            }
        }
    }

    private static func authentication() throws -> (FirebaseProjectConfiguration, FirebaseRESTAuthentication) {
        guard let url = Bundle.main.url(forResource: "RevivalFirebase", withExtension: "plist") else {
            throw RevivalFailure("Firebase configuration is missing from this build.")
        }
        let config = try FirebaseProjectConfiguration.load(plist: Data(contentsOf: url))
        let auth = try FirebaseRESTAuthentication(
            apiKey: config.apiKey,
            store: KeychainFirebaseSessionStore(projectID: config.projectID, bundleID: config.bundleID))
        return (config, auth)
    }

    private static func presentResult(on presenter: UIViewController, title: String, message: String) {
        var owner: UIViewController? = presenter
        while let presented = owner?.presentedViewController { owner = presented }
        guard let owner else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        owner.present(alert, animated: true)
    }
}
