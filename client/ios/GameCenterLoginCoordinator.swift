import Foundation
import GameKit
import RevivalTradingClient

/// Uses the game's existing Game Center authentication without replacing its handler.
@MainActor
public final class GameCenterLoginCoordinator {
    private let authentication: FirebaseRESTAuthentication
    public init(authentication: FirebaseRESTAuthentication) {
        self.authentication = authentication
    }

    public func signIn() async throws -> FirebaseSession {
        let player = GKLocalPlayer.local
        guard player.isAuthenticated else { throw FirebaseAuthenticationError.signInRequired }
        guard let bundleID = Bundle.main.bundleIdentifier else {
            throw FirebaseAuthenticationError.invalidConfiguration
        }
        let teamID = player.teamPlayerID
        let gameID = player.gamePlayerID
        let name = player.displayName
        let credential: GameCenterCredential = try await withCheckedThrowingContinuation { continuation in
            player.fetchItems { url, signature, salt, timestamp, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let url = url, let signature = signature, let salt = salt else {
                    continuation.resume(throwing: FirebaseAuthenticationError.invalidResponse)
                    return
                }
                continuation.resume(returning: GameCenterCredential(
                    teamPlayerID: teamID, gamePlayerID: gameID, publicKeyURL: url,
                    signature: signature, salt: salt, timestamp: timestamp, displayName: name))
            }
        }
        guard player.isAuthenticated, player.gamePlayerID == gameID, player.teamPlayerID == teamID else {
            throw FirebaseAuthenticationError.sessionChanged
        }
        let session = try await authentication.signIn(gameCenter: credential, bundleID: bundleID)
        guard player.isAuthenticated, player.gamePlayerID == gameID, player.teamPlayerID == teamID else {
            await authentication.signOut()
            throw FirebaseAuthenticationError.sessionChanged
        }
        return session
    }
}
