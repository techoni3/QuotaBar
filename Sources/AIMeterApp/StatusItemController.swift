import AIMeterCore
import AppKit
import SwiftUI

/// Owns the menu bar status item, its menu, and the HUD panel toggle.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    /// Preferred width; the overlay is clamped to the active screen.
    static let hudPanelWidth: CGFloat = 660

    private var statusItem: NSStatusItem!
    private var hudPanel: HUDPanel?
    private var settingsController: SettingsWindowController?
    private var statusMenu: NSMenu?
    private let viewModel: HUDViewModel
    private var tintTask: Task<Void, Never>?
    private let onCheckForUpdates: (() -> Void)?
    /// Lazy: the closure captures self, so it cannot run before super.init.
    private lazy var hotkey = GlobalHotkeyController { [weak self] in
        self?.toggleHUD()
    }

    init(refresher: UsageRefresher, vault: any CredentialVault, onCheckForUpdates: (() -> Void)? = nil) {
        viewModel = HUDViewModel(refresher: refresher, vault: vault)
        self.onCheckForUpdates = onCheckForUpdates
        super.init()
        tintTask = Task { [weak self] in
            for await state in refresher.updates {
                self?.applyIconState(StatusItemState.derive(from: state))
            }
        }
    }

    /// Aggregate menu-bar icon state (normal/warning/stale/critical) from the
    /// refresher's latest publish; updates on every tick.
    private func applyIconState(_ iconState: StatusItemState) {
        guard let button = statusItem?.button else { return }
        button.contentTintColor = iconState.statusItemColor
        button.setAccessibilityLabel(iconState.statusItemAccessibilityLabel)
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarImage()
        rebuildMenu()
        registerGlobalHotkey()

        // Left-click toggles the HUD directly; the menu stays on right-click.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.target = self
    }

    /// Registers the user-configured hotkey (spec Decision 6, default ⌘⇧U).
    private func registerGlobalHotkey() {
        hotkey.register(currentHotkeyChord())
    }

    private func currentHotkeyChord() -> HotkeyChord {
        let defaults = UserDefaults.standard
        let keyCode = defaults.object(forKey: SettingsKeys.hotkeyKeyCode) as? Int ?? SettingsDefaults.hotkeyKeyCode
        let modifiers = defaults.object(forKey: SettingsKeys.hotkeyModifiers) as? Int ?? SettingsDefaults.hotkeyModifiers
        return HotkeyChord(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show AIMeter", action: #selector(showHUD(_:)), keyEquivalent: "")
        if onCheckForUpdates != nil {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AIMeter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items {
            item.target = self
        }
        // terminate: targets first responder — keep default target for it.
        menu.items.last?.target = nil
        // NOTE: do NOT assign statusItem.menu — that makes macOS open the menu
        // on left-click and swallows the button action (Lcan-click = HUD fix).
        // The menu is kept only for the manual right-click/Ctrl popUp.
        statusMenu = menu
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        onCheckForUpdates?()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) else {
            toggleHUD()
            return
        }
        statusMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: statusItem.button!.bounds.height), in: statusItem.button)
    }

    @objc private func showHUD(_ sender: Any?) {
        showHUD()
    }

    private func toggleHUD() {
        if hudPanel?.isVisible == true {
            hudPanel?.orderOut(nil)
        } else {
            showHUD()
        }
    }

    private func showHUD() {
        if hudPanel == nil {
            hudPanel = makeHUDPanel()
        }
        // Spec Decision 4: refresh when the HUD opens.
        viewModel.refreshAll()
        positionAndShow(panel: hudPanel!)
    }

    private func makeHUDPanel() -> HUDPanel {
        let panel = HUDPanel()
        panel.delegate = self
        let hosting = NSHostingView(rootView: HUDRootView(viewModel: viewModel, openSettings: { [weak self] in
            self?.showSettings(nil)
        }, dismiss: { [weak panel] in
            panel?.orderOut(nil)
        }))
        panel.contentView = hosting
        return panel
    }

    private func positionAndShow(panel: NSPanel) {
        // Follow the pointer's screen, including when summoned by the hotkey.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }
        let rows = viewModel.visibleRows
        let heights = stride(from: 0, to: rows.count, by: 2).map { index in
            rows[index..<min(index + 2, rows.count)].map { 130 + CGFloat($0.windows.count) * 44 }.max() ?? 148
        }
        let height = max(280, 120 + heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * 14)
        let frame = HUDOverlayLayout.frame(in: screen.visibleFrame,
                                          preferredSize: NSSize(width: Self.hudPanelWidth, height: height))
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// A crisp template icon with no dependency on the installed SF Symbols set.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for (index, height) in [6.0, 10.0, 14.0].enumerated() {
                let bar = NSRect(x: 2 + CGFloat(index) * 5, y: 2, width: 3, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AIMeter usage"
        return image
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        // Connect/Disconnect + hotkey + manual-plan edits apply immediately.
        settingsController?.show(viewModel: viewModel, hotkeyChanged: { [weak self] in
            self?.hotkey.register(self?.currentHotkeyChord() ?? .defaults)
        }, plansChanged: { [weak self] in
            self?.viewModel.refresh(ProviderID("manual"))
        })
    }

    func windowWillClose(_ notification: Notification) {}
}

/// Non-activating floating panel used for the HUD.
@MainActor
final class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 220),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "AIMeter"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        appearance = NSAppearance(named: .vibrantDark)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc, even when no SwiftUI control has focus.
            cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}