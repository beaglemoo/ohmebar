import Foundation

enum OhmeError: LocalizedError {
    case notLoggedIn
    case badCredentials
    case apiError(status: Int, body: String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not logged in"
        case .badCredentials: return "Incorrect email or password"
        case .apiError(let status, let body):
            return "Ohme API error \(status): \(body.prefix(200))"
        case .decodingError(let detail): return "Unexpected API response: \(detail)"
        }
    }
}

/// Firebase email/password auth against Ohme's identity project.
/// Actor so concurrent API calls share a single login/refresh.
actor OhmeAuth {
    /// Ohme's public Firebase web API key, as shipped in the official apps and ohmepy.
    private static let googleAPIKey = "AIzaSyC8ZeZngm33tpOXLpbXeKfwtyZ1WrkbdBY"

    private let session: URLSession
    private var email: String?
    private var password: String?

    private var idToken: String?
    private var refreshToken: String?
    private var tokenBirth: Date = .distantPast

    init(session: URLSession = .shared) {
        self.session = session
    }

    func setCredentials(email: String, password: String) {
        self.email = email
        self.password = password
        idToken = nil
        refreshToken = nil
        tokenBirth = .distantPast
    }

    func clearCredentials() {
        email = nil
        password = nil
        idToken = nil
        refreshToken = nil
        tokenBirth = .distantPast
    }

    /// Returns a valid idToken, logging in or refreshing as needed.
    /// Tokens older than 45 minutes are refreshed (they expire at 60).
    func validToken(forceLogin: Bool = false) async throws -> String {
        if !forceLogin, let token = idToken {
            if Date().timeIntervalSince(tokenBirth) < 45 * 60 {
                return token
            }
            if let refreshed = try? await refresh() {
                return refreshed
            }
        }
        return try await login()
    }

    private func login() async throws -> String {
        guard let email, let password else { throw OhmeError.notLoggedIn }

        var request = URLRequest(
            url: URL(string: "https://www.googleapis.com/identitytoolkit/v3/relyingparty/verifyPassword?key=\(Self.googleAPIKey)")!
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "email": email,
            "password": password,
            "returnSecureToken": "true",
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OhmeError.decodingError("no HTTP response")
        }
        guard http.statusCode == 200 else { throw OhmeError.badCredentials }

        struct LoginResponse: Decodable {
            var idToken: String
            var refreshToken: String
        }
        let parsed = try JSONDecoder().decode(LoginResponse.self, from: data)
        idToken = parsed.idToken
        refreshToken = parsed.refreshToken
        tokenBirth = Date()
        return parsed.idToken
    }

    private func refresh() async throws -> String {
        guard let refreshToken else { throw OhmeError.notLoggedIn }

        var request = URLRequest(
            url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(Self.googleAPIKey)")!
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grantType": "refresh_token",
            "refreshToken": refreshToken,
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OhmeError.notLoggedIn
        }

        struct RefreshResponse: Decodable {
            var id_token: String
            var refresh_token: String
        }
        let parsed = try JSONDecoder().decode(RefreshResponse.self, from: data)
        idToken = parsed.id_token
        self.refreshToken = parsed.refresh_token
        tokenBirth = Date()
        return parsed.id_token
    }

    private func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(v)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }
}
