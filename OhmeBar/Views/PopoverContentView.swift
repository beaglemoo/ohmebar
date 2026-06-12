import SwiftUI

struct PopoverContentView: View {
    @ObservedObject var model: ChargerViewModel

    var body: some View {
        if model.isLoggedIn {
            ChargerView(model: model)
        } else {
            LoginView(model: model)
        }
    }
}

private struct ChargerView: View {
    @ObservedObject var model: ChargerViewModel
    @State private var editingTarget = false
    @State private var editingBattery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            powerSection
            Divider()
            targetSection
            if !model.slots.isEmpty {
                Divider()
                slotsSection
            }
            Divider()
            actions

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(14)
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            Image(systemName: model.status.symbolName)
                .foregroundColor(statusColor)
            Text(model.deviceName)
                .font(.headline)
            Spacer()
            Text(model.status.rawValue)
                .font(.subheadline)
                .foregroundColor(statusColor)
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .charging: return .green
        case .paused: return .orange
        case .pendingApproval: return .yellow
        case .unplugged, .unknown: return .secondary
        case .finished, .pluggedIn: return .blue
        }
    }

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                metric(String(format: "%.1f kW", model.powerWatts / 1000), label: "Power")
                metric(String(format: "%.0f A", model.powerAmps), label: "Current")
                if let volts = model.powerVolts {
                    metric(String(format: "%.0f V", volts), label: "Voltage")
                }
            }
            HStack(spacing: 16) {
                metric(String(format: "%.2f kWh", model.energyKWh), label: "Session")
                if model.batteryPercent > 0 {
                    metric("\(model.batteryPercent)%", label: "Battery")
                }
                Spacer()
                if model.bmwPairing == .linked {
                    Button("Sync from BMW") { model.syncBatteryFromBMW() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Button(editingBattery ? "Done" : "Set Battery") {
                    editingBattery.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if editingBattery {
                BatteryEditor(model: model, dismiss: { editingBattery = false })
            }
            BMWLinkSection(model: model)
        }
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Target: \(model.targetPercent)% by \(TargetTime.display(fromSeconds: model.targetTimeSeconds))")
                    .font(.subheadline)
                Spacer()
                Button(editingTarget ? "Done" : "Edit") {
                    editingTarget.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if editingTarget {
                TargetEditor(model: model, dismiss: { editingTarget = false })
            }
        }
    }

    private var slotsSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Charge slots")
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(model.slots.prefix(4), id: \.start) { slot in
                HStack {
                    Text("\(timeString(slot.start)) - \(timeString(slot.end))")
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    Text(String(format: "%.1f kWh", slot.energy))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private var actions: some View {
        HStack {
            switch model.status {
            case .pendingApproval:
                Button("Approve Charge") { model.approve() }
                    .buttonStyle(.borderedProminent)
            case .paused:
                Button("Resume") { model.resume() }
                Button("Max Charge") { model.setMaxCharge(true) }
            case .charging, .pluggedIn:
                Button("Pause") { model.pause() }
                Button("Max Charge") { model.setMaxCharge(true) }
                Button("Smart") { model.setMaxCharge(false) }
            case .finished, .unplugged, .unknown:
                Button("Refresh") { Task { await model.refresh() } }
            }
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .controlSize(.small)
    }

    private var footer: some View {
        HStack {
            if !model.isOnline {
                Label("Charger offline", systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else if let updated = model.lastUpdated {
                Text("Updated \(timeString(updated))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Sign Out") { model.signOut() }
                .buttonStyle(.link)
                .font(.caption2)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.link)
                .font(.caption2)
        }
    }
}

/// Links a BMW CarData client so the car's real SoC can be pushed into Ohme.
private struct BMWLinkSection: View {
    @ObservedObject var model: ChargerViewModel
    @State private var expanded = false
    @State private var clientId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.bmwPairing {
            case .linked:
                HStack {
                    Label("BMW linked", systemImage: "car.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let synced = model.bmwLastSync {
                        Text("synced \(synced, style: .time)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Unlink") { model.unlinkBMW() }
                        .buttonStyle(.link)
                        .font(.caption2)
                }

            case .waitingForApproval(let userCode, let url):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Approve in the BMW portal with code:")
                        .font(.caption)
                    HStack {
                        Text(userCode)
                            .font(.system(.body, design: .monospaced).weight(.bold))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Open BMW Portal") { NSWorkspace.shared.open(url) }
                            .controlSize(.small)
                        Button("Cancel") { model.unlinkBMW() }
                            .controlSize(.small)
                    }
                    Text("Waiting for approval...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

            case .unlinked:
                HStack {
                    Button(expanded ? "Hide BMW Setup" : "Link BMW CarData") {
                        expanded.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                    Spacer()
                }
                if expanded {
                    Text("In the BMW CarData portal create a CarData client with API access, select the battery descriptors, then paste the client ID:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("CarData client ID", text: $clientId)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Button("Link") {
                            model.linkBMW(clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .controlSize(.small)
                        .disabled(clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            if let error = model.bmwError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Corrects the car's current SoC in Ohme. Useful because BMW dropped
/// third-party API access, so Ohme can only extrapolate from this value.
private struct BatteryEditor: View {
    @ObservedObject var model: ChargerViewModel
    var dismiss: () -> Void

    @State private var percent: Double = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tell Ohme the car's actual charge level")
                .font(.caption2)
                .foregroundColor(.secondary)
            HStack {
                Slider(value: $percent, in: 0...100, step: 1)
                Text("\(Int(percent))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
                Button("Apply") {
                    model.setBatteryPercent(Int(percent))
                    dismiss()
                }
                .controlSize(.small)
            }
        }
        .onAppear { percent = Double(model.batteryPercent) }
    }
}

private struct TargetEditor: View {
    @ObservedObject var model: ChargerViewModel
    var dismiss: () -> Void

    @State private var percent: Double = 80
    @State private var time = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Slider(value: $percent, in: 10...100, step: 5)
                Text("\(Int(percent))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text("Ready by")
                    .font(.caption)
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Spacer()
                Button("Apply") {
                    let components = Calendar.current.dateComponents([.hour, .minute], from: time)
                    model.setTarget(
                        percent: Int(percent),
                        timeSeconds: TargetTime.seconds(
                            hour: components.hour ?? 0,
                            minute: components.minute ?? 0
                        )
                    )
                    dismiss()
                }
                .controlSize(.small)
            }
        }
        .onAppear {
            percent = Double(max(10, model.targetPercent))
            let c = TargetTime.components(fromSeconds: model.targetTimeSeconds)
            time = Calendar.current.date(
                bySettingHour: c.hour, minute: c.minute, second: 0, of: Date()
            ) ?? Date()
        }
    }
}
