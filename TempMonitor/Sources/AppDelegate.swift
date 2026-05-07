import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store: TemperatureStore!
    private var displayTimer: Timer?
    private var lastPopoverClose: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = TemperatureStore()

        setupStatusBar()
        setupPopover()

        store.start()
        updateMenuBarDisplay()

        displayTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateMenuBarDisplay()
        }

        print("[TempMonitor] Running. Click the menu bar icon to see details.")
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusBarClicked(_:))
            button.imagePosition = .imageLeading
        }
    }

    private func updateMenuBarDisplay() {
        guard let button = statusItem.button else { return }

        let temp = store.cpuTemperature

        // Choose thermometer icon based on temperature
        let symbolName: String
        if temp <= 0 {
            symbolName = "thermometer.medium"
        } else if temp < 50 {
            symbolName = "thermometer.low"
        } else if temp < 80 {
            symbolName = "thermometer.medium"
        } else {
            symbolName = "thermometer.high"
        }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Temperature")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image

        if temp > 0 {
            button.title = String(format: " %.0f°", temp)
        } else {
            button.title = " --°"
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(store: store))
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        // Prevent immediate reopen after transient close
        if let lastClose = lastPopoverClose, Date().timeIntervalSince(lastClose) < 0.3 {
            return
        }

        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
    }
}
