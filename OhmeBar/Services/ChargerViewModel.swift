import Foundation
import Combine

@MainActor
final class ChargerViewModel: ObservableObject {
    // Connection / auth
    @Published var isLoggedIn = false
    @Published var isLoading = false
    @Published var lastError: String?

    // Charger state
    @Published var status: ChargerStatus = .unknown
    @Published var isOnline = false
    @Published var powerWatts: Double = 0
    @Published var powerAmps: Double = 0
    @Published var powerVolts: Double?
    @Published var energyKWh: Double = 0
    @Published var batteryPercent: Int = 0
    @Published var slots: [ChargeSlot] = []
    @Published var targetPercent: Int = 0
    @Published var targetTimeSeconds: Int = 0
    @Published var deviceName: String = "Ohme"
    @Published var firmwareVersion: String = ""
    @Published var lastUpdated: Date?

    /// Charge in progress means status is neither unplugged nor pending approval.
    var chargeInProgress: Bool {
        status != .unplugged && status != .pendingApproval && status != .unknown
    }

    // BMW CarData link
    enum BMWPairingState: Equatable {
        case unlinked
        case waitingForApproval(userCode: String, url: URL)
        case linked
    }

    @Published var bmwPairing: BMWPairingState = .unlinked
    @Published var bmwLastSync: Date?
    @Published var bmwError: String?

    private let auth = OhmeAuth()
    private lazy var client = OhmeClient(auth: auth)
    private let bmw = BMWCarData()
    private var bmwPollTask: Task<Void, Never>?

    private var serial: String?
    private var carId: String?
    private var activeRuleId: String?
    private var nextRuleId: String?
    private var pollTask: Task<Void, Never>?
    private var popoverOpen = false

    private let popoverInterval: TimeInterval = 30
    private let backgroundInterval: TimeInterval = 120

    /// Number of in-flight operations; isLoading reflects this so two
    /// overlapping actions can't clear each other's spinner.
    private var pendingOps = 0 {
        didSet { isLoading = pendingOps > 0 }
    }

    private func beginOp() { pendingOps += 1 }
    private func endOp() { pendingOps = max(0, pendingOps - 1) }

    // MARK: - Lifecycle

    func start() {
        Task {
            if await bmw.isLinked {
                bmwPairing = .linked
            }
        }

        guard let email = KeychainStore.email,
              let password = KeychainStore.loadPassword()
        else { return }

        Task { await logIn(email: email, password: password, persist: false) }
    }

    func logIn(email: String, password: String, persist: Bool = true) async {
        beginOp()
        defer { endOp() }
        lastError = nil
        await auth.setCredentials(email: email, password: password)

        do {
            let account = try await client.fetchAccount()
            guard let device = account.chargeDevices?.first, let id = device.id else {
                throw OhmeError.decodingError("no charge device on account")
            }
            serial = id
            carId = account.cars?.first?.id
            deviceName = device.modelTypeDisplayName ?? "Ohme"
            firmwareVersion = device.firmwareVersionLabel ?? ""

            if persist {
                KeychainStore.email = email
                KeychainStore.savePassword(password)
            }
            isLoggedIn = true
            await refresh()
            startPolling()
        } catch {
            lastError = error.localizedDescription
            isLoggedIn = false
        }
    }

    func signOut() {
        pollTask?.cancel()
        pollTask = nil
        KeychainStore.deletePassword()
        KeychainStore.email = nil
        Task { await auth.clearCredentials() }
        isLoggedIn = false
        status = .unknown
        serial = nil
        carId = nil
        activeRuleId = nil
        nextRuleId = nil
        lastError = nil
    }

    func setPopoverOpen(_ open: Bool) {
        popoverOpen = open
        if isLoggedIn {
            startPolling()
            if open { Task { await refresh() } }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        let interval = popoverOpen ? popoverInterval : backgroundInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    // MARK: - Data refresh

    func refresh() async {
        do {
            let session = try await client.fetchChargeSession()
            let next = try await client.fetchNextSessionInfo()
            apply(session: session, next: next)
            lastError = nil
            lastUpdated = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(session: ChargeSession, next: NextSessionInfo) {
        let previousStatus = status
        status = session.status

        // On plug-in, sync the real SoC from BMW once so Ohme's target
        // calculation starts from an accurate figure.
        if bmwPairing == .linked,
           previousStatus == .unplugged,
           status == .pluggedIn || status == .pendingApproval || status == .charging {
            syncBatteryFromBMW()
        }
        isOnline = session.isOnline
        powerWatts = session.power?.watt ?? 0
        powerAmps = session.power?.amp ?? 0
        powerVolts = session.power?.volt
        energyKWh = session.energyKWh
        batteryPercent = session.batteryPercent
        slots = ChargeSlot.merged(from: session.allSessionSlots ?? [])
        activeRuleId = session.appliedRule?.id
        nextRuleId = next.rule?.id

        if status == .paused, let suspended = session.suspendedRule {
            targetPercent = suspended.targetPercent ?? 0
        } else if chargeInProgress, let applied = session.appliedRule {
            targetPercent = applied.targetPercent ?? 0
        } else {
            targetPercent = next.rule?.targetPercent ?? 0
        }

        if chargeInProgress, let applied = session.appliedRule {
            targetTimeSeconds = applied.targetTime ?? 0
        } else {
            targetTimeSeconds = next.rule?.targetTime ?? 0
        }
    }

    // MARK: - Controls

    func pause() { control { try await $0.client.pauseCharge(serial: $0.requireSerial()) } }
    func resume() { control { try await $0.client.resumeCharge(serial: $0.requireSerial()) } }
    func approve() { control { try await $0.client.approveCharge(serial: $0.requireSerial()) } }

    func setMaxCharge(_ enabled: Bool) {
        control { try await $0.client.setMaxCharge(serial: $0.requireSerial(), enabled: enabled) }
    }

    func setTarget(percent: Int?, timeSeconds: Int?) {
        control {
            guard let ruleId = $0.activeRuleId ?? $0.nextRuleId else {
                throw OhmeError.decodingError("no charge rule to update")
            }
            try await $0.client.setTarget(
                ruleId: ruleId, targetPercent: percent, targetTime: timeSeconds
            )
        }
    }

    /// Correct the car's current battery percentage in Ohme. Without a car
    /// API link, Ohme extrapolates the live SoC from this starting value.
    func setBatteryPercent(_ percent: Int) {
        control {
            guard let carId = $0.carId else {
                throw OhmeError.decodingError("no vehicle on account")
            }
            try await $0.client.setStateOfCharge(carId: carId, percent: percent)
        }
    }

    // MARK: - BMW CarData

    /// Begin linking a BMW CarData client: returns immediately, publishing
    /// the user code and verification URL, then polls until approved.
    func linkBMW(clientId: String) {
        bmwError = nil
        bmwPollTask?.cancel()
        bmwPollTask = Task {
            do {
                let info = try await bmw.startPairing(clientId: clientId)
                bmwPairing = .waitingForApproval(userCode: info.userCode, url: info.verificationURL)

                let deadline = Date().addingTimeInterval(Double(info.expiresIn))
                while !Task.isCancelled && Date() < deadline {
                    try await Task.sleep(nanoseconds: UInt64(info.pollInterval) * 1_000_000_000)
                    do {
                        try await bmw.pollForTokens(clientId: clientId, deviceCode: info.deviceCode)
                        bmwPairing = .linked
                        syncBatteryFromBMW()
                        return
                    } catch BMWCarData.BMWError.authorizationPending {
                        continue
                    }
                }
                if !Task.isCancelled {
                    bmwPairing = .unlinked
                    bmwError = "Pairing timed out - try again"
                }
            } catch {
                bmwPairing = .unlinked
                bmwError = error.localizedDescription
            }
        }
    }

    func unlinkBMW() {
        bmwPollTask?.cancel()
        Task { await bmw.unlink() }
        bmwPairing = .unlinked
        bmwLastSync = nil
        bmwError = nil
    }

    /// Fetch the car's real SoC from BMW CarData and push it into Ohme.
    func syncBatteryFromBMW() {
        guard bmwPairing == .linked else { return }
        Task {
            beginOp()
            defer { endOp() }
            bmwError = nil
            do {
                let reading = try await bmw.fetchBatterySoC()
                guard let carId else { throw OhmeError.decodingError("no vehicle on Ohme account") }
                try await client.setStateOfCharge(carId: carId, percent: reading.percent)
                bmwLastSync = Date()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await refresh()
            } catch {
                bmwError = error.localizedDescription
            }
        }
    }

    private func requireSerial() throws -> String {
        guard let serial else { throw OhmeError.notLoggedIn }
        return serial
    }

    /// Run a control action then re-poll shortly after, since the API
    /// takes a moment to reflect changes.
    private func control(_ action: @escaping (ChargerViewModel) async throws -> Void) {
        Task {
            beginOp()
            defer { endOp() }
            do {
                try await action(self)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refresh()
        }
    }
}
