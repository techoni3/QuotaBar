import AIMeterCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Holds the Settings window alive between invocations.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var onHotkeyChanged: (() -> Void)?
    private var onPlansChanged: (() -> Void)?

    func show(viewModel: HUDViewModel,
              hotkeyChanged: @escaping () -> Void,
              plansChanged: @escaping () -> Void) {
        onHotkeyChanged = hotkeyChanged
        onPlansChanged = plansChanged
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 740),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AIMeter Settings"
            window.contentMinSize = NSSize(width: 560, height: 540)
            window.contentView = NSHostingView(rootView: SettingsView(viewModel: viewModel,
                                                                      hotkeyChanged: hotkeyChanged,
                                                                      plansChanged: plansChanged))
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: false)
    }
}

/// Explicit page navigation with a single, top-aligned scroll surface.
/// Custom provider rows do not use Form's implicit label-column layout.
struct SettingsView: View {
    @ObservedObject var viewModel: HUDViewModel
    var hotkeyChanged: () -> Void = {}
    var onPlansChanged: () -> Void = {}

    @AppStorage(SettingsKeys.refreshIntervalSeconds) private var refreshInterval = SettingsDefaults.refreshIntervalSeconds
    @AppStorage(SettingsKeys.hotkeyKeyCode) private var hotkeyKeyCode = SettingsDefaults.hotkeyKeyCode
    @AppStorage(SettingsKeys.hotkeyModifiers) private var hotkeyModifiers = SettingsDefaults.hotkeyModifiers
    @AppStorage(SettingsKeys.credentialMethod(for: "claude")) private var claudeCredentialMethod = SettingsDefaults.credentialMethodKeychain

    private enum Page: String, CaseIterable {
        case polling = "Polling", general = "General", providers = "Providers", manual = "Manual"
    }

    @State private var page: Page = .providers
    @State private var plans: [ManualPlan]
    @State private var draftName = ""
    @State private var draftPlanName = ""
    @State private var draftPercent = 0
    @State private var draftHasReset = true
    @State private var draftResetDate = Date().addingTimeInterval(7 * 86_400)

    @State private var isRecordingHotkey = false
    @State private var draftedTokens: [String: String] = [:]
    @State private var connectError: String?
    @State private var hotkeyError: String?
    @State private var keyMonitor: Any?
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var helpFor: ProviderID?

    private let store: any ManualPlanStore

    init(viewModel: HUDViewModel,
         hotkeyChanged: @escaping () -> Void = {},
         plansChanged: @escaping () -> Void = {},
         store: any ManualPlanStore = UserDefaultsManualPlanStore()) {
        self.viewModel = viewModel
        self.hotkeyChanged = hotkeyChanged
        self.onPlansChanged = plansChanged
        self.store = store
        _plans = State(initialValue: store.loadPlans())
    }

    private var currentHotkey: HotkeyChord {
        HotkeyChord(keyCode: UInt32(hotkeyKeyCode), modifiers: UInt32(hotkeyModifiers))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings page", selection: $page) {
                ForEach(Page.allCases, id: \.self) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch page {
                    case .polling: pollingTab
                    case .general: generalTab
                    case .providers: providersTab
                    case .manual: manualTab
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 540)
        .onChange(of: plans) { _, newPlans in
            debouncedSave(newPlans)
        }
        .onDisappear {
            stopRecordingHotkey()
            saveTask?.cancel()
        }
    }

    // MARK: - Tabs

    private var pollingTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSection("Provider polling") {
                Stepper(value: $refreshInterval, in: 15...300, step: 5) {
                    LabeledContent {
                        Text("\(refreshInterval) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Refresh interval")
                    }
                }
                Text("Quota windows refresh on this interval, when the HUD opens, and on the HUD refresh button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSection("Global hotkey") {
                HStack {
                    Text("Summon HUD")
                    Spacer()
                    HStack(spacing: 10) {
                        Text(currentHotkey.displayString)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.white.opacity(0.08))
                            )
                        Button(isRecordingHotkey ? "Press a chord…" : "Record…") {
                            isRecordingHotkey ? stopRecordingHotkey() : startRecordingHotkey()
                        }
                        .controlSize(.small)
                    }
                }
                if let hotkeyError {
                    Text(hotkeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Record a keyboard shortcut (e.g. ⇧⌘U). It works from any app without permission prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            settingsSection("Launch at login") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            launchAtLoginEnabled = LaunchAtLogin.isEnabled
                            launchError = nil
                        } catch {
                            launchAtLoginEnabled = LaunchAtLogin.isEnabled
                            launchError = (error as? LaunchAtLoginError)?.displayText
                                ?? error.localizedDescription
                        }
                    }
                ))
                if LaunchAtLogin.requiresApproval {
                    Text("Approve AIMeter in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var providersTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSection("Claude credentials") {
                Picker("Credentials", selection: $claudeCredentialMethod) {
                    Text("Keychain (live)").tag(SettingsDefaults.credentialMethodKeychain)
                    Text("Imported token").tag(SettingsDefaults.credentialMethodImport)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            settingsSection("Providers") {
                ForEach(viewModel.rows) { row in
                    providerRow(row)
                    if row.id != viewModel.rows.last?.id { Divider() }
                }
                if let connectError {
                    Text(connectError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Import a token this provider already issued (Claude Code keychain, ~/.codex/auth.json, ~/.gemini/…, ~/.pi). Manual plans live on the Manual tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func providerRow(_ row: ProviderRowState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.enabled ? statusColor(row.status) : .gray)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name)
                        .font(.subheadline.weight(.semibold))
                    Text(statusText(row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Enable", isOn: Binding(
                    get: { row.enabled },
                    set: { viewModel.setEnabled(row.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("Enable \(row.name)")
                Button {
                    helpFor = (helpFor == row.id ? nil : row.id)
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Help for \(row.name)")
                .help(helpText(for: row.id))
                .popover(isPresented: Binding(
                    get: { helpFor == row.id },
                    set: { isPresented in helpFor = isPresented ? row.id : nil }
                )) {
                    Text(helpText(for: row.id))
                        .font(.caption)
                        .padding(10)
                        .frame(width: 280)
                }
            }
            if row.enabled, row.status == .unauthorized || row.status == .unavailable {
                HStack(spacing: 6) {
                    SecureField("Token", text: tokenBinding(row.id))
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isConnecting)
                        .accessibilityLabel("\(row.name) token")
                    Button(viewModel.isConnecting ? "…" : "Connect") {
                        connect(row.id)
                    }
                    .disabled(viewModel.isConnecting || trimmedToken(row.id).isEmpty)
                    .controlSize(.small)
                    Button("Disconnect") {
                        viewModel.forget(row.id)
                        draftedTokens[row.id.rawValue] = nil
                        viewModel.refresh(row.id)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func tokenBinding(_ id: ProviderID) -> Binding<String> {
        Binding(
            get: { draftedTokens[id.rawValue] ?? "" },
            set: { draftedTokens[id.rawValue] = $0 }
        )
    }

    private func trimmedToken(_ id: ProviderID) -> String {
        (draftedTokens[id.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func connect(_ id: ProviderID) {
        let token = trimmedToken(id)
        connectError = nil
        Task {
            do {
                try await viewModel.connect(id, token: token)
                draftedTokens[id.rawValue] = nil
            } catch {
                connectError = "\(rowName(id)): couldn't store token (\(error))"
            }
        }
    }

    private func rowName(_ id: ProviderID) -> String {
        viewModel.rows.first { $0.id == id }?.name ?? id.rawValue
    }

    private func statusText(_ row: ProviderRowState) -> String {
        guard row.enabled else { return "Disabled" }
        switch row.status {
        case .ok: return "Connected"
        case .local: return "Connected (local)"
        case .unauthorized: return "Not connected"
        case .unavailable: return "Unavailable"
        case .disabled: return "Disabled"
        }
    }

    private func statusColor(_ status: ProviderStatus) -> Color {
        switch status {
        case .ok, .local: return .green
        case .unauthorized: return .orange
        case .unavailable: return .red
        case .disabled: return .gray
        }
    }

    private func helpText(for id: ProviderID) -> String {
        switch id.rawValue {
        case "github-copilot":
            return "GitHub Copilot — auto-connects via Pi (github-copilot OAuth). Add via Pi auth at ~/.pi/agent/auth.json. Business seat with no quota window shows as connected at 0%. Auth expired → Reconnect. AIMeter never writes to ~/.pi and never logs tokens."
        case "openrouter":
            return "OpenRouter — auto-connects via Pi (openrouter api_key). Stores key in ~/.pi/agent/auth.json. Fetch is GET https://openrouter.ai/api/v1/credits or /auth/key. No key → Not connected (hidden from HUD). 401 → Auth expired → Reconnect. AIMeter never writes to ~/.pi."
        case "ollama":
            return "Ollama — Pi cloud key (ollama) → Ollama Cloud; else local daemon at localhost:11434."
        case "opencode":
            return "OpenCode — File (~/.local/share/opencode/auth.json) > Pi (opencode-go) > Vault."
        case "antigravity":
            return "Antigravity — local language server → Pi OAuth → keychain. Never writes back."
        case "claude":
            return "Claude — Keychain (live) or Imported token."
        case "codex":
            return "Codex — Pi openai-codex OAuth > ~/.codex/auth.json > Vault import. AIMeter reads credential files without writing or logging tokens."
        default:
            return "Connect or Disconnect this provider. Pi providers auto-connect and never log tokens."
        }
    }

    private var manualTab: some View {
        settingsSection("Manual subscriptions") {
            VStack(alignment: .leading, spacing: 16) {
                if plans.isEmpty {
                    Text("No manual subscriptions yet — add one below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach($plans) { $plan in
                    ManualPlanRowView(plan: $plan) {
                        plans.removeAll { $0.id == $plan.wrappedValue.id }
                    }
                }
                Divider()
                addPlanSection
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Hotkey recording

    private func startRecordingHotkey() {
        isRecordingHotkey = true
        hotkeyError = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return nil }

            // Esc cancels recording.
            if event.keyCode == UInt32(kVK_Escape), event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                self.stopRecordingHotkey()
                return nil
            }

            let chord = HotkeyChord(keyCode: UInt32(event.keyCode),
                                    modifiers: Self.carbonModifiers(from: event.modifierFlags))
            let isFunctionKey = Self.functionKeyCodes.contains(chord.keyCode)
            // Require a modifier unless it's a bare function key.
            guard chord.hasModifier || isFunctionKey else { return nil }

            hotkeyKeyCode = Int(chord.keyCode)
            hotkeyModifiers = Int(chord.modifiers)
            self.isRecordingHotkey = false
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            self.keyMonitor = nil
            self.hotkeyError = nil
            self.hotkeyChanged()
            return nil // swallow the recorded keystroke
        }
    }

    private func stopRecordingHotkey() {
        isRecordingHotkey = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    /// Carbon virtual key codes of F1–F19 (values are non-sequential).
    static let functionKeyCodes: Set<UInt32> = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62,
                                                0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B,
                                                0x71, 0x6A, 0x40, 0x4F, 0x50]

    // MARK: - Manual plans

    /// Debounced persist: typing in a row fires many onChange events; coalesce
    /// them into one store write + one HUD refresh 400ms after the last edit.
    private func debouncedSave(_ plans: [ManualPlan]) {
        saveTask?.cancel()
        let store = self.store
        let notify = self.onPlansChanged
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            store.savePlans(plans)
            notify()
        }
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
}

/// One editable manual-subscription row (shared by the Manual tab).
private struct ManualPlanRowView: View {
    let plan: Binding<ManualPlan>
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: plan.name)
                    .textFieldStyle(.roundedBorder)
                TextField("Plan", text: plan.planName.unwrapped(default: ""))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(plan.wrappedValue.name)")
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
}

enum SettingsKeys {
    static let refreshIntervalSeconds = "refreshIntervalSeconds"
    static let hotkeyKeyCode = "hotkeyKeyCode"
    static let hotkeyModifiers = "hotkeyModifiers"
    static func credentialMethod(for provider: String) -> String { "credentialMethod.\(provider)" }
}

enum SettingsDefaults {
    static let refreshIntervalSeconds = 60
    static let hotkeyKeyCode = Int(HotkeyChord.defaults.keyCode)
    static let hotkeyModifiers = Int(HotkeyChord.defaults.modifiers)
    static let credentialMethodKeychain = "keychain"
    static let credentialMethodImport = "import"
}

extension Binding where Value == String? {
    /// Edits an optional string field, keeping exactly what the user typed
    /// (including a lone "0"); clears to nil only when the field is emptied.
    func unwrapped(default defaultValue: String) -> Binding<String> {
        Binding<String>(
            get: { wrappedValue ?? defaultValue },
            set: { newValue in
                if newValue.isEmpty { wrappedValue = nil }
                else { wrappedValue = newValue }
            }
        )
    }
}