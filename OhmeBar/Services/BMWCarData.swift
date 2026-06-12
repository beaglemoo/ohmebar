import Foundation
import CryptoKit

/// Client for BMW CarData, BMW's official customer data API.
/// The user creates a CarData client in the BMW portal (My BMW account ->
/// CarData -> "Technical access" -> Create CarData Client) and pastes the
/// client ID here. Auth is the OAuth 2.0 Device Code flow with PKCE.
/// Endpoints and descriptors mirror the bmw-cardata-ha integration.
actor BMWCarData {
    private static let deviceCodeURL = "https://customer.bmwgroup.com/gcdm/oauth/device/code"
    private static let tokenURL = "https://customer.bmwgroup.com/gcdm/oauth/token"
    private static let apiBase = "https://api-cardata.bmwgroup.com"
    /// Match the scope set used by the working HA integrations exactly -
    /// the consent step is picky and api-only requests have been seen to
    /// come back as access_denied. Requires BOTH portal toggles enabled.
    private static let scope = "authenticate_user openid cardata:api:read cardata:streaming:read"

    /// Current HV battery state of charge in percent; the same figure the
    /// My BMW app shows. charging.level is the fallback.
    private static let socDescriptor = "vehicle.drivetrain.batteryManagement.header"
    private static let socFallbackDescriptor = "vehicle.drivetrain.electricEngine.charging.level"

    struct DeviceCodeInfo {
        var userCode: String
        var verificationURL: URL
        var deviceCode: String
        var pollInterval: Int
        var expiresIn: Int
    }

    struct BatteryReading {
        var percent: Int
        var timestamp: Date?
        var vin: String
    }

    enum BMWError: LocalizedError {
        case notLinked
        case authorizationPending
        case authError(String)
        case apiError(status: Int, body: String)
        case noData(String)

        var errorDescription: String? {
            switch self {
            case .notLinked: return "BMW account not linked"
            case .authorizationPending: return "Waiting for approval in the BMW portal"
            case .authError(let detail): return "BMW auth failed: \(detail)"
            case .apiError(let status, let body):
                return "BMW API error \(status): \(body.prefix(200))"
            case .noData(let detail): return "BMW: \(detail)"
            }
        }
    }

    private let session: URLSession

    private var accessToken: String?
    private var tokenExpiry: Date = .distantPast
    private var codeVerifier: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Stored state

    var clientId: String? {
        UserDefaults.standard.string(forKey: "bmwClientId")
    }

    var vin: String? {
        UserDefaults.standard.string(forKey: "bmwVin")
    }

    private var containerId: String? {
        get { UserDefaults.standard.string(forKey: "bmwContainerId") }
        set { UserDefaults.standard.set(newValue, forKey: "bmwContainerId") }
    }

    var isLinked: Bool {
        clientId != nil && KeychainStore.load(account: KeychainStore.bmwRefreshTokenAccount) != nil
    }

    func unlink() {
        UserDefaults.standard.removeObject(forKey: "bmwClientId")
        UserDefaults.standard.removeObject(forKey: "bmwVin")
        UserDefaults.standard.removeObject(forKey: "bmwContainerId")
        KeychainStore.delete(account: KeychainStore.bmwRefreshTokenAccount)
        accessToken = nil
        tokenExpiry = .distantPast
    }

    // MARK: - Device code pairing

    /// Begin pairing: returns a user code to enter at the verification URL.
    func startPairing(clientId: String) async throws -> DeviceCodeInfo {
        let verifier = Self.randomVerifier()
        codeVerifier = verifier
        UserDefaults.standard.set(clientId, forKey: "bmwClientId")

        let body: [String: String] = [
            "client_id": clientId,
            "scope": Self.scope,
            "response_type": "device_code",
            "code_challenge": Self.codeChallenge(for: verifier),
            "code_challenge_method": "S256",
        ]

        let (data, status) = try await postForm(url: Self.deviceCodeURL, fields: body)
        guard status == 200 else {
            throw BMWError.authError("device code request failed (\(status)): \(String(data: data, encoding: .utf8) ?? "")")
        }

        struct DeviceCodeResponse: Decodable {
            var user_code: String
            var device_code: String
            var verification_uri_complete: String?
            var verification_uri: String?
            var interval: Int?
            var expires_in: Int?
        }
        let parsed = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        // BMW's approval page can auto-fill a stale code from an earlier
        // attempt, which silently denies the current one. Passing the code
        // in the URL forces the right one (same trick as bmw-cardata-ha).
        var urlString = parsed.verification_uri_complete ?? parsed.verification_uri ?? ""
        if parsed.verification_uri_complete == nil, !urlString.isEmpty {
            urlString += "?user_code=\(parsed.user_code)"
        }
        guard let url = URL(string: urlString) else {
            throw BMWError.authError("no verification URL in response")
        }
        return DeviceCodeInfo(
            userCode: parsed.user_code,
            verificationURL: url,
            deviceCode: parsed.device_code,
            pollInterval: parsed.interval ?? 5,
            expiresIn: parsed.expires_in ?? 900
        )
    }

    /// Poll once for tokens after the user approves in the BMW portal.
    /// Throws authorizationPending while the user has not approved yet.
    func pollForTokens(clientId: String, deviceCode: String) async throws {
        guard let verifier = codeVerifier else {
            throw BMWError.authError("pairing not started")
        }

        let body: [String: String] = [
            "client_id": clientId,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode,
            "code_verifier": verifier,
        ]
        let (data, status) = try await postForm(url: Self.tokenURL, fields: body)

        if status == 200 {
            try storeTokens(from: data)
            return
        }

        struct ErrorResponse: Decodable { var error: String? }
        let error = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
        if error == "authorization_pending" || error == "slow_down" {
            throw BMWError.authorizationPending
        }
        // BMW's token endpoint intermittently returns 5xx; keep polling.
        if status >= 500 {
            throw BMWError.authorizationPending
        }
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        throw BMWError.authError(
            error ?? "token request failed (\(status)): \(responseBody.prefix(200))"
        )
    }

    // MARK: - Tokens

    private func storeTokens(from data: Data) throws {
        struct TokenResponse: Decodable {
            var access_token: String
            var refresh_token: String
            var expires_in: Int?
        }
        let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = parsed.access_token
        tokenExpiry = Date().addingTimeInterval(Double(parsed.expires_in ?? 3600) - 120)
        KeychainStore.save(parsed.refresh_token, account: KeychainStore.bmwRefreshTokenAccount)
    }

    private func validAccessToken() async throws -> String {
        if let token = accessToken, Date() < tokenExpiry {
            return token
        }
        guard let clientId,
              let refreshToken = KeychainStore.load(account: KeychainStore.bmwRefreshTokenAccount)
        else { throw BMWError.notLinked }

        let body: [String: String] = [
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        let (data, status) = try await postForm(url: Self.tokenURL, fields: body)
        guard status == 200 else {
            throw BMWError.authError("token refresh failed (\(status)): \(String(data: data, encoding: .utf8) ?? "")")
        }
        try storeTokens(from: data)
        guard let token = accessToken else { throw BMWError.notLinked }
        return token
    }

    // MARK: - Data

    /// Fetch the car's current battery percent. Each call costs 1-2 requests
    /// of BMW's 50/day API quota, so call sparingly.
    /// The telematics endpoint requires a "container" (a registered descriptor
    /// set); one is created on first use and reused after that.
    func fetchBatterySoC() async throws -> BatteryReading {
        let vin: String
        if let stored = self.vin {
            vin = stored
        } else {
            vin = try await fetchVIN()
            UserDefaults.standard.set(vin, forKey: "bmwVin")
        }

        let container = try await ensureContainer()
        let data: Data
        do {
            data = try await apiGet(
                path: "/customers/vehicles/\(vin)/telematicData?containerId=\(container)"
            )
        } catch BMWError.apiError(let status, _) where (400...404).contains(status) {
            // Container may have been deleted in the portal - recreate once.
            containerId = nil
            let fresh = try await ensureContainer()
            data = try await apiGet(
                path: "/customers/vehicles/\(vin)/telematicData?containerId=\(fresh)"
            )
        }

        struct DescriptorValue: Decodable {
            var timestamp: String?
            var unit: String?
            var value: String?
        }
        struct TelematicResponse: Decodable {
            var telematicData: [String: DescriptorValue]?
            var data: [String: DescriptorValue]?
        }
        let parsed = try JSONDecoder().decode(TelematicResponse.self, from: data)
        let values = parsed.telematicData ?? parsed.data ?? [:]

        // Use the freshest reading: during a charge, charging.level updates
        // more often than batteryManagement.header.
        func parseDate(_ ts: String?) -> Date? {
            guard let ts else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
        }

        let readings: [(percent: Double, timestamp: Date?)] =
            [Self.socDescriptor, Self.socFallbackDescriptor].compactMap { key in
                guard let reading = values[key], let raw = reading.value,
                      let percent = Double(raw)
                else { return nil }
                return (percent, parseDate(reading.timestamp))
            }

        guard let freshest = readings.max(by: {
            ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast)
        }) else {
            throw BMWError.noData(
                "no battery reading returned - check the SoC descriptors are selected in the CarData portal"
            )
        }

        return BatteryReading(
            percent: Int(freshest.percent.rounded()),
            timestamp: freshest.timestamp,
            vin: vin
        )
    }

    /// Find the account's VIN via the vehicle mappings endpoint.
    /// Prefers the PRIMARY mapping when several vehicles exist.
    private func fetchVIN() async throws -> String {
        let data = try await apiGet(path: "/customers/vehicles/mappings")
        let json = try JSONSerialization.jsonObject(with: data)

        var mappings: [[String: Any]] = []
        if let list = json as? [[String: Any]] {
            mappings = list
        } else if let dict = json as? [String: Any] {
            mappings = (dict["mappings"] ?? dict["vehicles"]) as? [[String: Any]] ?? []
        }
        for mapping in mappings {
            let type = (mapping["mappingType"] as? String)?.uppercased()
            if type == nil || type == "PRIMARY", let vin = mapping["vin"] as? String {
                return vin
            }
        }
        if let vin = Self.firstVIN(in: json) {
            return vin
        }
        throw BMWError.noData("no VIN found in vehicle mappings")
    }

    /// Create (or reuse) the descriptor container required by telematicData.
    private func ensureContainer() async throws -> String {
        if let containerId { return containerId }

        let body: [String: Any] = [
            "name": "OhmeBar HV Battery",
            "purpose": "Battery state of charge for Ohme sync",
            "technicalDescriptors": [Self.socDescriptor, Self.socFallbackDescriptor],
        ]
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: Self.apiBase + "/customers/containers")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "x-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...201).contains(status) else {
            throw BMWError.apiError(
                status: status, body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = parsed["containerId"] as? String
        else { throw BMWError.noData("container creation response missing containerId") }

        containerId = id
        return id
    }

    /// Recursively scan a JSON structure for a "vin" key.
    private static func firstVIN(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            for (key, value) in dict {
                if key.lowercased() == "vin", let vin = value as? String, vin.count == 17 {
                    return vin
                }
                if let found = firstVIN(in: value) { return found }
            }
        } else if let array = json as? [Any] {
            for item in array {
                if let found = firstVIN(in: item) { return found }
            }
        }
        return nil
    }

    // MARK: - HTTP plumbing

    private func apiGet(path: String) async throws -> Data {
        let token = try await validAccessToken()
        var request = URLRequest(url: URL(string: Self.apiBase + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "x-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BMWError.apiError(status: 0, body: "no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw BMWError.apiError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    private func postForm(url: String, fields: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(
            fields.map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
            .utf8
        )

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    // MARK: - PKCE

    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
