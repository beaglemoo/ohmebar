import XCTest
@testable import OhmeBar

final class OhmeModelsTests: XCTestCase {

    func decodeSession(_ json: String) throws -> ChargeSession {
        try JSONDecoder().decode(ChargeSession.self, from: Data(json.utf8))
    }

    // MARK: - Status derivation

    func testStatusDisconnected() throws {
        let session = try decodeSession(#"{"mode": "DISCONNECTED"}"#)
        XCTAssertEqual(session.status, .unplugged)
    }

    func testStatusPendingApproval() throws {
        let session = try decodeSession(#"{"mode": "PENDING_APPROVAL"}"#)
        XCTAssertEqual(session.status, .pendingApproval)
    }

    func testStatusStopped() throws {
        let session = try decodeSession(#"{"mode": "STOPPED"}"#)
        XCTAssertEqual(session.status, .paused)
    }

    func testStatusFinished() throws {
        let session = try decodeSession(#"{"mode": "FINISHED_CHARGE"}"#)
        XCTAssertEqual(session.status, .finished)
    }

    func testStatusChargingWhenPowerFlowing() throws {
        let session = try decodeSession(
            #"{"mode": "SMART_CHARGE", "power": {"watt": 7200, "amp": 32, "volt": 238}}"#
        )
        XCTAssertEqual(session.status, .charging)
    }

    func testStatusPluggedInWhenNoPower() throws {
        let session = try decodeSession(#"{"mode": "SMART_CHARGE", "power": {"watt": 0}}"#)
        XCTAssertEqual(session.status, .pluggedIn)
    }

    // MARK: - Session fields

    func testFullSessionDecode() throws {
        let json = #"""
        {
            "mode": "SMART_CHARGE",
            "power": {"watt": 7200.5, "amp": 32, "volt": 238},
            "batterySoc": {"wh": 14600, "percent": 64.0, "timestamp": 1718155000000, "source": "EXTRAPOLATION"},
            "car": {"batterySoc": {"percent": 22.0, "timestamp": 1718150000000, "source": "USER"}},
            "chargerStatus": {"online": true},
            "appliedRule": {"id": "rule-123", "targetPercent": 80, "targetTime": 27000},
            "allSessionSlots": [
                {"startTimeMs": 1718150400000, "endTimeMs": 1718154000000, "watts": 7200},
                {"startTimeMs": 1718154000000, "endTimeMs": 1718157600000, "watts": 7200},
                {"startTimeMs": 1718164800000, "endTimeMs": 1718168400000, "watts": 7200}
            ]
        }
        """#
        let session = try decodeSession(json)
        XCTAssertEqual(session.status, .charging)
        XCTAssertTrue(session.isOnline)
        XCTAssertEqual(session.batteryPercent, 64, "freshest reading (live extrapolation) wins over stale user-entered SoC")
        XCTAssertEqual(session.energyKWh, 14.6, accuracy: 0.001)
        XCTAssertEqual(session.appliedRule?.id, "rule-123")
        XCTAssertEqual(session.appliedRule?.targetTime, 27000)
    }

    func testBatteryFallsBackToSessionSoc() throws {
        let session = try decodeSession(#"{"mode": "STOPPED", "batterySoc": {"percent": 42.5}}"#)
        XCTAssertEqual(session.batteryPercent, 43, "fractional percent rounds")
    }

    func testBatteryUsesCarSocWhenFresher() throws {
        let session = try decodeSession(#"""
        {
            "mode": "SMART_CHARGE",
            "batterySoc": {"percent": 30, "timestamp": 1000},
            "car": {"batterySoc": {"percent": 55, "timestamp": 2000}}
        }
        """#)
        XCTAssertEqual(session.batteryPercent, 55)
    }

    // MARK: - Slot merging

    func testAdjacentSlotsMerge() throws {
        let slots: [SessionSlot] = [
            SessionSlot(startTimeMs: 0, endTimeMs: 3_600_000, watts: 7000),
            SessionSlot(startTimeMs: 3_600_000, endTimeMs: 7_200_000, watts: 7000),
            SessionSlot(startTimeMs: 10_800_000, endTimeMs: 14_400_000, watts: 7000),
        ]
        let merged = ChargeSlot.merged(from: slots)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].energy, 14.0, accuracy: 0.001)
        XCTAssertEqual(merged[1].energy, 7.0, accuracy: 0.001)
        XCTAssertEqual(
            merged[0].end.timeIntervalSince(merged[0].start), 7200, accuracy: 0.1
        )
    }

    // MARK: - Target time helpers

    func testTargetTimeConversion() {
        XCTAssertEqual(TargetTime.components(fromSeconds: 27000).hour, 7)
        XCTAssertEqual(TargetTime.components(fromSeconds: 27000).minute, 30)
        XCTAssertEqual(TargetTime.seconds(hour: 7, minute: 30), 27000)
        XCTAssertEqual(TargetTime.display(fromSeconds: 27000), "07:30")
        XCTAssertEqual(TargetTime.display(fromSeconds: 0), "00:00")
        XCTAssertEqual(TargetTime.display(fromSeconds: 86340), "23:59")
    }

    // MARK: - Other responses

    func testAccountDecode() throws {
        let json = #"""
        {
            "chargeDevices": [{
                "id": "CHARGER-SERIAL-1",
                "modelTypeDisplayName": "Ohme Home Pro",
                "firmwareVersionLabel": "v2.43"
            }],
            "cars": [{"id": "car-uuid-1", "name": null, "model": {"make": "BMW"}}]
        }
        """#
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        XCTAssertEqual(account.chargeDevices?.first?.id, "CHARGER-SERIAL-1")
        XCTAssertEqual(account.chargeDevices?.first?.modelTypeDisplayName, "Ohme Home Pro")
        XCTAssertEqual(account.cars?.first?.id, "car-uuid-1")
    }

    func testNextSessionInfoDecode() throws {
        let json = #"{"rule": {"id": "next-rule", "targetPercent": 80, "targetTime": 27000}}"#
        let info = try JSONDecoder().decode(NextSessionInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.rule?.id, "next-rule")
        XCTAssertEqual(info.rule?.targetPercent, 80)
    }

    // MARK: - BMW CarData PKCE

    func testCodeChallengeMatchesRFC7636Example() {
        // Verifier/challenge pair from RFC 7636 appendix B.
        let challenge = BMWCarData.codeChallenge(
            for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        )
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomVerifierIsBase64URL() {
        let verifier = BMWCarData.randomVerifier()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testTolerantDecodeOfUnknownFields() throws {
        let session = try decodeSession(
            #"{"mode": "SMART_CHARGE", "someNewField": {"a": 1}, "another": [1, 2]}"#
        )
        XCTAssertEqual(session.status, .pluggedIn)
    }
}
