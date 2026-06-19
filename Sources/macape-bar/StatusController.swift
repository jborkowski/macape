import AppKit
import MacapeCore

@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let client = ControlClient()
    private var eventsTask: Task<Void, Never>?
    private var status = StatusSnapshot(
        enabled: true,
        mappingCount: 0,
        holdTimeoutMs: 200,
        layerEnabled: true,
        stuckRecoveries: 0,
        connectedClients: 0
    )
    private var metrics = MetricsSnapshot(
        eventsSeen: 0,
        tapsEmitted: 0,
        modifierPromotions: 0,
        queueFlushes: 0,
        tapDisableRecoveries: 0,
        stuckRecoveries: 0,
        callbackMaxUs: 0,
        callbackP99Us: 0,
        slowCallbacks: 0
    )
    private var connected = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "macape")
        }
        rebuildMenu()
    }

    func start() {
        eventsTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.events()
            await self.client.start()
            await self.refreshStats()
            for await event in stream {
                self.handle(event)
            }
        }
    }

    private func refreshStats() async {
        try? await client.send(.status)
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task { await refreshStats() }
    }

    func stop() {
        eventsTask?.cancel()
        Task { await client.stop() }
    }

    @MainActor
    private func handle(_ event: DaemonEvent) {
        connected = true
        switch event {
        case .status(let snapshot):
            status = snapshot
        case .metrics(let snapshot):
            metrics = snapshot
        case .stuck:
            refreshIcon(stuck: true)
            rebuildMenu()
            return
        case .configReloaded, .error:
            break
        }
        refreshIcon(stuck: metrics.stuckRecoveries > 0)
        rebuildMenu()
    }

    private func refreshIcon(stuck: Bool) {
        guard let button = statusItem.button else { return }
        let symbol: String
        if !connected {
            symbol = "keyboard.badge.exclamationmark"
        } else if !status.enabled {
            symbol = "keyboard.fill"
        } else if stuck {
            symbol = "keyboard.badge.ellipsis"
        } else {
            symbol = "keyboard"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "macape")
        button.image?.isTemplate = true
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let state = connected ? (status.enabled ? "Active" : "Paused") : "Disconnected"
        menu.addItem(withTitle: "macape: \(state)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: status.enabled ? "Disable" : "Enable",
            action: #selector(toggleEnabled)
        ))
        menu.addItem(actionItem(title: "Release Stuck Keys", action: #selector(clearStuck)))
        menu.addItem(actionItem(title: "Reload Config", action: #selector(reloadConfig)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Events: \(metrics.eventsSeen)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Stuck recoveries: \(metrics.stuckRecoveries)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Callback p99: \(metrics.callbackP99Us)us", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit macape-bar", action: #selector(quit)))
        menu.delegate = self
        statusItem.menu = menu
    }

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleEnabled() {
        Task { try? await client.send(.toggle) }
    }

    @objc private func clearStuck() {
        Task { try? await client.send(.clearStuck) }
    }

    @objc private func reloadConfig() {
        Task { try? await client.send(.reload) }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
