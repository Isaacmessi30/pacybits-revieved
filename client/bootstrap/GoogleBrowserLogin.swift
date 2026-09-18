import UIKit
import AuthenticationServices
import CryptoKit
import Security

/// Native OAuth authorization-code flow with PKCE; passwords stay in Google's browser.
@MainActor
final class GoogleBrowserLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let configuration: FirebaseProjectConfiguration
    private let authentication: FirebaseRESTAuthentication
    private var anchor: UIWindow?
    private var browser: ASWebAuthenticationSession?
    private let transport: TradingHTTPTransport

    init(configuration: FirebaseProjectConfiguration, authentication: FirebaseRESTAuthentication,
         transport: TradingHTTPTransport = URLSessionTradingTransport()) {
        self.configuration = configuration
        self.authentication = authentication
        self.transport = transport
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }
    func signIn(presenting presenter: UIViewController) async throws -> FirebaseSession {
        guard browser == nil, let window = presenter.view.window else {
            throw RevivalFailure("Google login could not find an active app window.")
        }
        let verifier = try Self.random(), state = try Self.random()
        anchor = window
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let redirect = configuration.reversedClientID + ":/oauth2redirect"
        var authorization = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        authorization.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        defer { browser = nil; anchor = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authorization.url!, callbackURLScheme: configuration.reversedClientID) { url, error in
                if let error = error { continuation.resume(throwing: error) }
                else if let url = url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: FirebaseAuthenticationError.invalidResponse) }
            }
            session.presentationContextProvider = self
            browser = session
            if !session.start() { continuation.resume(throwing: RevivalFailure("Could not open Google sign-in.")) }
        }
        let code = try GoogleOAuthCallback.code(from: callback, redirectURI: redirect, expectedState: state)
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "grant_type", value: "authorization_code")
        ]
        request.httpBody = Data(form.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200, data.count <= 65536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String:Any],
              let token = object["id_token"] as? String, !token.isEmpty else {
            throw RevivalFailure("Google could not finish sign-in (HTTP \(response.statusCode)).")
        }
        // Firebase verifies Google's token; it creates the account on first sign-in.
        return try await authentication.signIn(googleIDToken: token)
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RevivalFailure("Secure sign-in could not be started.")
        }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
