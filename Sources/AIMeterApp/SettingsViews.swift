import AIMeterCore
import AppKit
import SwiftUI

/// Holds the Settings window alive between invocations.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var onPlansChanged: (() -> Void)?

    func show(onPlansChanged changed: @escaping () -> Void) {
        onPlansChanged = changed
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "AIMeter Settings"
            window.contentView = NSHostingView(rootView: SettingsView(onPlansChanged: changed))
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: false)
    }
}

/// Settings: polling, hotkey placeholder, per-provider credential info, and
/// manual subscriptions (persisted; renders like live rows minus refresh).
struct SettingsView: View {
    var onPlansChanged: () -> Void = {}

    @AppStorage(SettingsKeys.refreshIntervalSeconds) private var refreshInterval = SettingsDefaults.refreshIntervalSeconds
    @AppStorage(SettingsKeys.hotkeyDisplay) private var hotkeyDisplay = SettingsDefaults.hotkeyDisplay
    @AppStorage(SettingsKeys.credentialMethod(for: "claude")) private var claudeCredentialMethod = SettingsDefaults.credentialMethodKeychain

    @State private var plans: [ManualPlan]
    @State private var draftName = ""
    @State private var draftPlanName = ""
    @State private var draftPercent = 0
    @State private var draftHasReset = true
    @State private var draftResetDate = Date().addingTimeInterval(7 * 86_400)

    private let store: any ManualPlanStore

    init(onPlansChanged: @escaping () -> Void = {}, store: any ManualPlanStore = UserDefaultsManualPlanStore()) {
        self.onPlansChanged = onPlansChanged
        self.store = store
        _plans = State(initialValue: store.loadPlans())
    }

    var body: some View {
        ScrollView {
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
                    Picker("Claude credentials", selection: $claudeCredentialMethod) {
                        Text("Keychain (live)").tag(SettingsDefaults.credentialMethodKeychain)
                        Text("Imported token").tag(SettingsDefaults.credentialMethodImport)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Codex") { Text("Reads ~/.codex/auth.json").foregroundStyle(.secondary) }
                    LabeledContent("OpenCode") { Text("Reads ~/.local/share/opencode/auth.json").foregroundStyle(.secondary) }
                    LabeledContent("Antigravity") { Text("App running → local service; else keychain").foregroundStyle(.secondary) }
                    LabeledContent("Ollama") { Text("Local daemon — no subscription quota").foregroundStyle(.secondary) }
                    Text("Enable or disable any provider from its HUD row; the choice persists.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Manual subscriptions") {
                    if plans.isEmpty {
                        Text("No manual subscriptions yet — add one below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach($plans) { $plan in
                        manualPlanRow($plan)
                    }
                    addPlanSection
                }
            }
            .padding(20)
            .onChange(of: plans) {
                persist()
            }
        }
        .frame(width: 420, height: 620)
    }

    private func manualPlanRow(_ plan: Binding<ManualPlan>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: plan.name)
                    .textFieldStyle(.roundedBorder)
                TextField("Plan", text: plan.planName.unwrapped(default: ""))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Button(role: .destructive) {
                    plans.removeAll { $0.id == plan.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this subscription")
            }
            HStack {
                Stepper(value: plan.usedPercent, in: 0...100) {
                    Text("\(plan.wrappedValue.usedPercent)% used")
                        .monospacedDigit()
                        .font(.callout)
                }
                Spacer()
                Toggle("Resets", isOn: Binding(
                    get: { plan.wrappedValue.resetsAt != nil },
                    set: { on in
                        if on {
                            plan.wrappedValue.resetsAt = plan.wrappedValue.resetsAt ?? Date().addingTimeInterval(7 * 86_400)
                        } else {
                            plan.wrappedValue.resetsAt = nil
                        }
                    }
                ))
                .controlSize(.mini)
                if plan.wrappedValue.resetsAt != nil {
                    DatePicker("", selection: Binding(
                        get: { plan.wrappedValue.resetsAt ?? Date() },
                        set: { plan.wrappedValue.resetsAt = $0 }
                    ), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 150)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var addPlanSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add subscription")
                .font(.subheadline.weight(.semibold))
            HStack {
                TextField("Name (e.g. NotebookLM)", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                TextField("Plan (optional)", text: $draftPlanName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }
            HStack {
                Stepper(value: $draftPercent, in: 0...100) {
                    Text("\(draftPercent)% used")
                        .monospacedDigit()
                        .font(.callout)
                }
                Spacer()
                Toggle("Resets", isOn: $draftHasReset)
                    .controlSize(.mini)
                if draftHasReset {
                    DatePicker("", selection: $draftResetDate,
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .controlSize(.mini)
                        .frame(width: 150)
                }
            }
            Button("Add") {
                let name = draftName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                plans.append(ManualPlan(
                    name: name,
                    planName: draftPlanName.isEmpty ? nil : draftPlanName,
                    usedPercent: draftPercent,
                    resetsAt: draftHasReset ? draftResetDate : nil
                ))
                draftName = ""
                draftPlanName = ""
                draftPercent = 0
                draftHasReset = true
                draftResetDate = Date().addingTimeInterval(7 * 86_400)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 6)
    }

    /// Persist edits immediately and nudge the Manual provider row.
    private func persist() {
        store.savePlans(plans)
        onPlansChanged()
    }
}

enum SettingsKeys {
    static let refreshIntervalSeconds = "refreshIntervalSeconds"
    static let hotkeyDisplay = "hotkeyDisplay"
    static func credentialMethod(for provider: String) -> String { "credentialMethod.\(provider)" }
}

enum SettingsDefaults {
    static let refreshIntervalSeconds = 60
    static let hotkeyDisplay = "⌘⇧U"
    static let credentialMethodKeychain = "keychain"
    static let credentialMethodImport = "import"
}

extension Binding where Value == String? {
    /// Convenience binding for optional text fields (empty → nil).
    func unwrapped(default defaultValue: String) -> Binding<String> {
        Binding<String>(
            get: { wrappedValue ?? defaultValue },
            set: { wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}