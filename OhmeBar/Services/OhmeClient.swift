import Foundation

/// Async client for the unofficial Ohme cloud API (api.ohme.io).
/// Endpoint shapes mirror ohmepy, the library behind the Home Assistant integration.
final class OhmeClient {
    private let auth: OhmeAuth
    private let session: URLSession
    private static let baseURL = "https://api.ohme.io"

    init(auth: OhmeAuth, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    // MARK: - Reads

    func fetchAccount() async throws -> Account {
        try await requestJSON("GET", "/v1/users/me/account")
    }

    /// Fetches the current charge session, retrying briefly while the
    /// backend reports a transient CALCULATING/DELIVERING state.
    func fetchChargeSession() async throws -> ChargeSession {
        var last: ChargeSession?
        for attempt in 0..<3 {
            let sessions: [ChargeSession] = try await requestJSON("GET", "/v1/chargeSessions")
            guard let first = sessions.first else {
                throw OhmeError.decodingError("empty charge session list")
            }
            last = first
            if first.mode != "CALCULATING" && first.mode != "DELIVERING" {
                return first
            }
            if attempt < 2 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        guard let last else {
            throw OhmeError.decodingError("empty charge session list")
        }
        return last
    }

    func fetchNextSessionInfo() async throws -> NextSessionInfo {
        try await requestJSON("GET", "/v1/chargeSessions/nextSessionInfo")
    }

    // MARK: - Controls

    func pauseCharge(serial: String) async throws {
        try await requestVoid("POST", "/v1/chargeSessions/\(serial)/stop")
    }

    func resumeCharge(serial: String) async throws {
        try await requestVoid("POST", "/v1/chargeSessions/\(serial)/resume")
    }

    func approveCharge(serial: String) async throws {
        try await requestVoid("PUT", "/v1/chargeSessions/\(serial)/approve?approve=true")
    }

    func setMaxCharge(serial: String, enabled: Bool) async throws {
        try await requestVoid(
            "PUT",
            "/v2/charge-devices/\(serial)/charge-sessions/active/\(serial)/max-charge?enabled=\(enabled)"
        )
    }

    /// Update target percent and/or time on a charge rule.
    /// targetTime is seconds since midnight.
    func setTarget(ruleId: String, targetPercent: Int?, targetTime: Int?) async throws {
        var body: [String: Any] = [:]
        if let targetPercent { body["targetPercent"] = targetPercent }
        if let targetTime { body["targetTime"] = targetTime }
        guard !body.isEmpty else { return }

        try await requestVoid(
            "PATCH",
            "/v2/users/me/charge-rules/\(ruleId)?persist=true&recalculateSession=true",
            body: body
        )
    }

    /// Tell Ohme the vehicle's current state of charge. With no car API link,
    /// Ohme extrapolates session SoC from this starting figure.
    func setStateOfCharge(carId: String, percent: Int) async throws {
        try await requestVoid(
            "PUT",
            "/v1/car/\(carId)/state-of-charge",
            body: ["currentChargePercent": percent]
        )
    }

    // MARK: - Plumbing

    private func requestJSON<T: Decodable>(
        _ method: String, _ path: String, body: [String: Any]? = nil
    ) async throws -> T {
        let data = try await requestData(method, path, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OhmeError.decodingError("\(path): \(error)")
        }
    }

    private func requestVoid(
        _ method: String, _ path: String, body: [String: Any]? = nil
    ) async throws {
        _ = try await requestData(method, path, body: body)
    }

    private func requestData(
        _ method: String, _ path: String, body: [String: Any]?
    ) async throws -> Data {
        var token = try await auth.validToken()

        for attempt in 0..<2 {
            var request = URLRequest(url: URL(string: Self.baseURL + path)!)
            request.httpMethod = method
            request.setValue("Firebase \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("OhmeBar/1.0", forHTTPHeaderField: "User-Agent")
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OhmeError.decodingError("no HTTP response")
            }

            if http.statusCode == 401 && attempt == 0 {
                token = try await auth.validToken(forceLogin: true)
                continue
            }
            guard http.statusCode == 200 else {
                throw OhmeError.apiError(
                    status: http.statusCode,
                    body: String(data: data, encoding: .utf8) ?? ""
                )
            }
            return data
        }
        throw OhmeError.notLoggedIn
    }
}
