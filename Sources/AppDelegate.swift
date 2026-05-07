import AppKit
import Carbon
import SwiftUI

extension Notification.Name {
    static let voicePasteOpenSettings = Notification.Name("voicePasteOpenSettings")
    static let voicePasteConfigChanged = Notification.Name("voicePasteConfigChanged")
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store: VoiceStore!
    private var hotKeyRef: EventHotKeyRef?
    private var lastPopoverClose: Date?
    private var displayTimer: Timer?
    private var cancellable: Any?
    private var settingsWindow: NSWindow?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = VoiceStore()

        setupStatusBar()
        setupPopover()
        registerHotKey()

        NotificationCenter.default.addObserver(
            forName: .voicePasteOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.openSettingsWindow() }
        }

        // Update menu bar icon when state changes
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateMenuBarDisplay()
        }
        updateMenuBarDisplay()

        let savedKey = KeychainStore.getKey(forProvider: store.config.providerId) ?? ""
        if savedKey.isEmpty {
            showConfigurationAlert()
        }

        print("[VoicePaste] Ready. Press Cmd+Shift+R or click menu bar icon.")
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusBarClicked(_:))
            button.imagePosition = .imageLeading
            // Keep menu-bar metrics (size, ascent, descent) identical to the
            // default. We only swap in the "monospaced numbers" feature so the
            // timer text width does NOT change as digits tick (0:12 -> 0:13),
            // which would otherwise drift NSPopover's arrow.
            let baseFont = NSFont.menuBarFont(ofSize: 0)
            let monoDescriptor = baseFont.fontDescriptor.addingAttributes([
                .featureSettings: [
                    [
                        NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
                    ]
                ]
            ])
            button.font = NSFont(descriptor: monoDescriptor, size: 0) ?? baseFont
        }
    }

    @MainActor
    private func updateMenuBarDisplay() {
        guard let button = statusItem.button else { return }

        switch store.state {
        case .idle:
            let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "VoicePaste")
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.contentTintColor = nil

        case .recording:
            button.image = nil
            button.title = "● REC \(store.formatDuration(store.recordingDuration))"
            button.contentTintColor = .red

        case .processing:
            let image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Processing")
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.contentTintColor = nil
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        // Match PopoverView's fixed frame (width: 340, height: 560). A FIXED
        // contentSize keeps NSPopover's top edge anchored to the status item;
        // an intrinsic-sized popover would flip/shift when content grows. Long
        // sections scroll inside the SwiftUI ScrollView instead.
        popover.contentSize = NSSize(width: 340, height: 560)
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

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
    }

    // MARK: - Global Hot Key (Cmd+Shift+R)

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: 0x56505354, id: 1)

        var eventType = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_: EventHandlerCallRef?, _: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    appDelegate.store.toggle()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            nil
        )

        RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    // MARK: - Config Alert

    @MainActor
    private func showConfigurationAlert() {
        NSApp.activate(ignoringOtherApps: true)

        if !FileManager.default.fileExists(atPath: Config.configPath.path) {
            try? Config.defaultConfig.save()
        }

        let alert = NSAlert()
        alert.messageText = "VoicePaste: API Key Required"
        alert.informativeText = "Open Settings to choose a provider and paste your API key."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            openSettingsWindow()
        }
    }

    // MARK: - Settings Window

    @MainActor
    func openSettingsWindow() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(store: store, onClose: { [weak self] in
            self?.settingsWindow?.close()
        })
        let host = NSHostingController(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "VoicePaste Settings"
        win.contentViewController = host
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

// MARK: - NSWindowDelegate (for settings window cleanup)

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            settingsWindow = nil
        }
    }
}
