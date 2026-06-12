import AppKit
import SwiftUI
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    let model = ChargerViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        observeModel()
        model.start()
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "bolt.slash",
                accessibilityDescription: "Ohme charger"
            )
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func observeModel() {
        model.$status.combineLatest(model.$lastError)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status, error in
                let symbol = error == nil ? status.symbolName : "exclamationmark.triangle"
                let detail = error ?? status.rawValue
                self?.statusItem?.button?.image = NSImage(
                    systemSymbolName: symbol,
                    accessibilityDescription: "Ohme: \(detail)"
                )
                self?.statusItem?.button?.toolTip = "Ohme: \(detail)"
            }
            .store(in: &cancellables)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: - Popover

    private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverContentView(model: model)
        )
        self.popover = popover

        if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
        model.setPopoverOpen(true)
    }

    func popoverDidClose(_ notification: Notification) {
        model.setPopoverOpen(false)
        popover = nil
    }

    // MARK: - Context menu

    private func showContextMenu() {
        let menu = NSMenu()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let versionItem = NSMenuItem(title: "OhmeBar \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)

        if model.isLoggedIn {
            let signOut = NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: "")
            signOut.target = self
            menu.addItem(signOut)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OhmeBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func refreshNow() {
        Task { await model.refresh() }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch at login toggle failed: \(error)")
        }
    }

    @objc private func signOut() {
        model.signOut()
    }
}
