// Compile in an iOS target with the official GoogleSignIn package and RevivalTradingClient.
import UIKit
import GoogleSignIn
import RevivalTradingClient

enum RevivalLoginError: Error {
    case bundleIDMismatch
    case missingIDToken
}

@MainActor
final class GoogleLoginCoordinator {
    let authentication: FirebaseRESTAuthentication
    private let configuration: FirebaseProjectConfiguration

    init(configuration: FirebaseProjectConfiguration, authentication: FirebaseRESTAuthentication) throws {
        guard Bundle.main.bundleIdentifier == configuration.bundleID else { throw RevivalLoginError.bundleIDMismatch }
        self.configuration = configuration
        self.authentication = authentication
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: configuration.clientID)
    }

    func signIn(presenting: UIViewController) async throws -> FirebaseSession {
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting)
        guard let token = result.user.idToken?.tokenString else { throw RevivalLoginError.missingIDToken }
        return try await authentication.signIn(googleIDToken: token)
    }

    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme == configuration.reversedClientID else { return false }
        return GIDSignIn.sharedInstance.handle(url)
    }

    func signOut(trading: TradingClient) async {
        GIDSignIn.sharedInstance.signOut()
        await authentication.signOut()
        await trading.resetSession()
    }
}
