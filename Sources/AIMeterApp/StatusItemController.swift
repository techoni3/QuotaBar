import AIMeterCore
import AppKit
import SwiftUI

/// Owns the menu bar status item, its menu, and the HUD panel toggle.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    /// Fixed HUD width — the 2-column provider-card grid (see HUDRootView).
    static let hudPanelWidth: CGFloat = 660

    private var statusItem: NSStatusItem!
    private var hudPanel: HUDPanel?
    private var settingsController: SettingsWindowController?
    private let viewModel: HUDViewModel
    private var tintTask: Task<Void, Never>?
    /// Lazy: the closure captures self, so it cannot run before super.init.
    private lazy var hotkey = GlobalHotkeyController { [weak self] in
        self?.toggleHUD()
    }

    init(refresher: UsageRefresher, vault: any CredentialVault) {
        viewModel = HUDViewModel(refresher: refresher, vault: vault)
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
        // "gauge.with.dial" does not exist in this OS's SF Symbols set — a nil
        // image silently blanks the status item. Use "gauge" and never allow a
        // nil symbol to leave the item invisible.
        if let image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "AIMeter") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "AIM"
            NSLog("AIMeter: 'gauge' symbol unavailable; falling back to text status item")
        }
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AIMeter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items {
            item.target = self
        }
        // terminate: targets first responder — keep default target for it.
        menu.items.last?.target = nil
        statusItem.menu = menu
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) else {
            toggleHUD()
            return
        }
        statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: statusItem.button!.bounds.height), in: statusItem.button)
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
        let hosting = NSHostingView(rootView: HUDRootView(viewModel: viewModel))
        panel.contentView = hosting
        // Auto-size to the content: width is fixed by the 2-column card grid,
        // height follows the fitted content (clamped so long lists scroll).
        let fitting = hosting.fittingSize
        let size = NSSize(width: Self.hudPanelWidth,
                          height: min(max(fitting.height, 120), 720))
        panel.setContentSize(size)
        return panel
    }

    private func positionAndShow(panel: NSPanel) {
        let button = statusItem.button!
        if let window = button.window {
            panel.setFrameOrigin(statusItemAnchorOrigin(panel: panel, button: button, window: window))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless() // non-activating: show without stealing focus from the front app
    }

    private func statusItemAnchorOrigin(panel: NSPanel, button: NSStatusBarButton, window: NSWindow) -> NSPoint {
        let screen = window.screen ?? NSScreen.main!
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = window.convertToScreen(buttonRectInWindow)
        let x = max(screen.visibleFrame.minX,
                    min(buttonRectOnScreen.midX - panel.frame.width / 2,
                        screen.visibleFrame.maxX - panel.frame.width))
        // Anchor directly under the status item (Audit fix: was screen.minY,
        // which put the panel at the BOTTOM of the screen).
        let y = buttonRectOnScreen.minY - panel.frame.height - 8
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        // Hotkey + manual-plan edits should apply immediately.
        settingsController?.show(hotkeyChanged: { [weak self] in
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
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
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

        if #available(macOS 26, *) {
            // Liquid Glass: tinted chrome matches the modern HUD look.
            appearance = NSAppearance(named: .vibrantDark)
        }
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}