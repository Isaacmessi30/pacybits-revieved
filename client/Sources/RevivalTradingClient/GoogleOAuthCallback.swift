import Foundation

public enum GoogleOAuthCallback {
    public static func code(from url: URL, redirectURI: String, expectedState: String) throws -> String {
        guard !expectedState.isEmpty,
              let received = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(string: redirectURI),
              received.scheme == expected.scheme, received.host == expected.host,
              received.path == expected.path, received.user == nil, received.password == nil,
              received.port == nil, received.fragment == nil else {
            throw FirebaseAuthenticationError.invalidResponse
        }
        let values = Dictionary(grouping: received.queryItems ?? [], by: \.name)
        guard values["state"]?.count == 1, values["state"]?.first?.value == expectedState,
              values["error"] == nil, values["code"]?.count == 1,
              let code = values["code"]?.first?.value, !code.isEmpty else {
            throw FirebaseAuthenticationError.invalidResponse
        }
        return code
    }
}
