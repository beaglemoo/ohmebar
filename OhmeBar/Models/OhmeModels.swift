import Foundation

// MARK: - Derived charger state

enum ChargerStatus: String {
    case unplugged = "Unplugged"
    case pendingApproval = "Pending Approval"
    case paused = "Paused"
    case finished = "Finished"
    case charging = "Charging"
    case pluggedIn = "Plugged In"
    case unknown = "Unknown"

    var symbolName: String {
        switch self {
        case .charging: return "bolt.fill"
        case .pluggedIn: return "bolt"
        case .paused: return "pause.circle"
        case .pendingApproval: return "exclamationmark.circle"
        case .finished: return "checkmark.circle"
        case .unplugged: return "bolt.slash"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum ChargerMode: String {
    case smart = "SMART_CHARGE"
    case max = "MAX_CHARGE"
    case paused = "STOPPED"
}

// MARK: - API responses

/// Element of GET /v1/chargeSessions
struct ChargeSession: Decodable {
    struct Power: Decodable {
        var watt: Double?
        var amp: Double?
        var volt: Double?
    }

    struct BatterySoc: Decodable {
        var wh: Double?
        var percent: Double?
        /// Unix milliseconds of when this reading was taken.
        var timestamp: Double?
        /// "USER" (entered at plug-in), "EXTRAPOLATION" (live estimate), or car API.
        var source: String?
    }

    struct ChargerHardwareStatus: Decodable {
        var online: Bool?
    }

    struct Car: Decodable {
        var batterySoc: BatterySoc?
    }

    var mode: String?
    var power: Power?
    var batterySoc: BatterySoc?
    var car: Car?
    var chargerStatus: ChargerHardwareStatus?
    var appliedRule: ChargeRule?
    var suspendedRule: ChargeRule?
    var allSessionSlots: [SessionSlot]?

    var status: ChargerStatus {
        switch mode {
        case "PENDING_APPROVAL": return .pendingApproval
        case "DISCONNECTED": return .unplugged
        case "STOPPED": return .paused
        case "FINISHED_CHARGE": return .finished
        case nil: return .unknown
        default:
            return (power?.watt ?? 0) > 0 ? .charging : .pluggedIn
        }
    }

    var isOnline: Bool { chargerStatus?.online ?? false }

    /// Battery percent, preferring the freshest reading. The session-level
    /// value is Ohme's live extrapolation; the car-level value can be a stale
    /// user-entered figure from plug-in time.
    var batteryPercent: Int {
        let readings = [batterySoc, car?.batterySoc].compactMap { $0 }
        let freshest = readings.max { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
        return Int((freshest?.percent ?? 0).rounded())
    }

    /// Energy delivered this session in kWh.
    var energyKWh: Double {
        max(0, (batterySoc?.wh ?? 0) / 1000)
    }
}

/// A charge rule: applied (current session), suspended, or next scheduled.
struct ChargeRule: Decodable {
    var id: String?
    var targetPercent: Int?
    /// Seconds since midnight.
    var targetTime: Int?
    var preconditioningEnabled: Bool?
    var preconditionLengthMins: Int?
}

/// Element of allSessionSlots in a charge session.
struct SessionSlot: Decodable {
    /// Unix milliseconds.
    var startTimeMs: Double?
    var endTimeMs: Double?
    var watts: Double?

    var start: Date? { startTimeMs.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var end: Date? { endTimeMs.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// A charge slot for display, with adjacent API slots merged.
struct ChargeSlot: Equatable {
    var start: Date
    var end: Date
    /// Energy delivered in this slot in kWh.
    var energy: Double

    static func merged(from sessionSlots: [SessionSlot]) -> [ChargeSlot] {
        var slots: [ChargeSlot] = []
        for raw in sessionSlots {
            guard let start = raw.start, let end = raw.end else { continue }
            let hours = end.timeIntervalSince(start) / 3600
            let energy = ((raw.watts ?? 0) * hours / 1000 * 100).rounded() / 100
            if let last = slots.last, last.end == start {
                slots[slots.count - 1] = ChargeSlot(
                    start: last.start, end: end, energy: last.energy + energy
                )
            } else {
                slots.append(ChargeSlot(start: start, end: end, energy: energy))
            }
        }
        return slots
    }
}

/// GET /v1/chargeSessions/nextSessionInfo
struct NextSessionInfo: Decodable {
    var rule: ChargeRule?
}

/// GET /v1/users/me/account
struct Account: Decodable {
    struct ChargeDevice: Decodable {
        var id: String?
        var modelTypeDisplayName: String?
        var firmwareVersionLabel: String?
    }

    struct Car: Decodable {
        var id: String?
        var name: String?
    }

    var chargeDevices: [ChargeDevice]?
    /// The currently selected vehicle is the first entry.
    var cars: [Car]?
}

// MARK: - Time helpers

enum TargetTime {
    /// Convert seconds-since-midnight to (hour, minute).
    static func components(fromSeconds seconds: Int) -> (hour: Int, minute: Int) {
        (seconds / 3600, (seconds % 3600) / 60)
    }

    /// Convert (hour, minute) to seconds-since-midnight.
    static func seconds(hour: Int, minute: Int) -> Int {
        hour * 3600 + minute * 60
    }

    static func display(fromSeconds seconds: Int) -> String {
        let c = components(fromSeconds: seconds)
        return String(format: "%02d:%02d", c.hour, c.minute)
    }
}
