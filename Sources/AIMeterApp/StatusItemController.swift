import AppKit
import SwiftUI

/// Owns the menu bar status item, its menu, and the HUD panel toggle.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var hudPanel: HUDPanel?
    private var settingsController: SettingsWindowController?

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dial",
                                           accessibilityDescription: "AIMeter")
        statusItem.button?.image?.isTemplate = true
        rebuildMenu()

        // Left-click toggles the HUD directly; the menu stays on right-click.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.target = self
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
        positionAndShow(panel: hudPanel!)
    }

    private func makeHUDPanel() -> HUDPanel {
        let panel = HUDPanel()
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: HUDRootView())
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
        let y = screen.visibleFrame.minY
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.show()
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