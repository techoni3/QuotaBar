import AIMeterCore
import AppKit
import SwiftUI

/// Holds the Settings window alive between invocations.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "AIMeter Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: false)
    }
}

/// M1 settings: stub rows persisted to UserDefaults.
struct SettingsView: View {
    @AppStorage(SettingsKeys.refreshIntervalSeconds) private var refreshInterval = SettingsDefaults.refreshIntervalSeconds
    @AppStorage(SettingsKeys.hotkeyDisplay) private var hotkeyDisplay = SettingsDefaults.hotkeyDisplay

    var body: some View {
        Form {
            Section("Provider polling") {
                Stepper(value: $refreshInterval, in: 15...300, step: 5) {
                    LabeledContent {
                        Text("\(refreshInterval) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Refresh interval")
                    }
                }
            }
            Section("General") {
                LabeledContent("Global hotkey") {
                    Text(hotkeyDisplay)
                        .foregroundStyle(.secondary)
                }
                Text("Hotkey recording arrives in M4.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Section("Providers") {
                Text("Connect providers from the HUD panel (menu bar icon). Claude reads Claude Code's keychain entry; Codex reads ~/.codex/auth.json. Imported tokens live in AIMeter's own keychain item.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 380, height: 240)
    }
}

enum SettingsKeys {
    static let refreshIntervalSeconds = "refreshIntervalSeconds"
    static let hotkeyDisplay = "hotkeyDisplay"
}

enum SettingsDefaults {
    static let refreshIntervalSeconds = 60
    static let hotkeyDisplay = "⌘⇧U"
}