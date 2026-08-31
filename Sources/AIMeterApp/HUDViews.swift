import AIMeterCore
import SwiftUI

/// Identifiable wrapper for the hoisted single connect sheet.
private struct ConnectTarget: Identifiable {
    let id: ProviderID
}

/// Root content of the HUD panel: one card per provider.
struct HUDRootView: View {
    @ObservedObject var viewModel: HUDViewModel

    private var connectTarget: Binding<ConnectTarget?> {
        Binding(
            get: { viewModel.connectSheetRow.map { ConnectTarget(id: $0) } },
            set: { if $0 == nil { viewModel.connectSheetRow = nil } }
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("AIMeter")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh all")
            }
            .padding(.horizontal, 4)

            if viewModel.rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                              alignment: .leading,
                              spacing: 12) {
                        ForEach(viewModel.rows) { row in
                            ProviderCard(row: row,
                                         viewModel: viewModel)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: StatusItemController.hudPanelWidth)
        .background(HUDChrome())
        // Single hoisted connect sheet (Audit fix: a per-card .sheet inside an
        // NSPanel never attached; now the root presents exactly one sheet).
        .sheet(item: connectTarget) { target in
            ConnectTokenSheet(providerID: target.id,
                              providerName: viewModel.displayName(for: target.id) ?? target.id.rawValue,
                              viewModel: viewModel)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No providers connected yet")
                .font(.headline)
            Text("Connect Claude, Codex and others below.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
    }
}

private struct ProviderCard: View {
    let row: ProviderRowState
    @ObservedObject var viewModel: HUDViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: Self.iconName(for: row.id))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true) // decorative; the row label conveys status
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel("\(row.name), \(statusVoiceOverText)")
                if let plan = row.planName {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                statusChip
                Button {
                    viewModel.refresh(row.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(!row.enabled)
                .help("Refresh \(row.name)")
                .accessibilityLabel("Refresh \(row.name)")
                Toggle("", isOn: Binding(
                    get: { row.enabled },
                    set: { viewModel.setEnabled(row.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Enable \(row.name)")
            }

            if !row.enabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if row.isKeychainDenied {
                // Keychain ACL prompt denied → guide to the import fallback.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keychain access was denied — import your token instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        if let detail = row.errorText {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Connect…") {
                            viewModel.connectSheetRow = row.id
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Connect \(row.name) by importing a token")
                    }
                }
            } else if row.status == .unauthorized {
                HStack {
                    Text(row.errorText ?? "Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect…") {
                        viewModel.connectSheetRow = row.id
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Connect \(row.name)")
                }
            } else if let error = row.errorText {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let last = row.lastSuccessAt {
                        Text("Data from \(last.formatted(date: .abbreviated, time: .shortened)) is stale.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else if !row.windows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(row.windows) { window in
                        UsageBarView(
                            title: window.title,
                            percent: window.percent,
                            tint: window.tint,
                            countdown: window.countdown
                        )
                    }
                }
                if let fetched = row.fetchedAt {
                    Text("Updated \(fetched.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                // Successful fetch with no windows (e.g. Manual with no plans).
                Text("No plans yet — add them in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        )
    }

    /// Per-provider SF Symbol: claude/codex/opencode/antigravity/ollama/manual.
    private static func iconName(for id: ProviderID) -> String {
        switch id.rawValue {
        case "claude": return "sparkles"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "opencode": return "terminal"
        case "antigravity": return "scope"
        case "ollama": return "bolt"
        case "manual": return "pencil"
        default: return "gauge"
        }
    }

    /// Small status chip in the card header (OK / Watch / Critical / Local / Off).
    private var statusChip: some View {
        let (text, color): (String, Color)
        if !row.enabled {
            (text, color) = ("Off", .gray)
        } else if row.status == .local {
            (text, color) = ("Local", .blue)
        } else if !row.windows.isEmpty {
            switch row.windows.map(\.tint).max(by: { $0.severityRank < $1.severityRank }) {
            case .red: (text, color) = ("Critical", .red)
            case .amber: (text, color) = ("Watch", .orange)
            default: (text, color) = ("OK", .green)
            }
        } else {
            (text, color) = ("—", .gray)
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .accessibilityLabel("\(row.name) status: \(text)")
    }

    private var statusVoiceOverText: String {
        switch row.status {
        case .ok: return "connected"
        case .unauthorized: return "not connected"
        case .disabled: return "disabled"
        case .unavailable: return "unavailable"
        case .local: return "local"
        }
    }
}

private struct UsageBarView: View {
    let title: String
    let percent: Int
    let tint: UsageTint
    let countdown: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let countdown {
                    Text(countdown)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(Color(nsColor: tint.color))
                        .frame(width: geo.size.width * CGFloat(percent) / 100)
                }
            }
            .frame(height: 8)
            HStack(spacing: 6) {
                Text("\(percent)%")
                    .font(.caption2.bold())
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: tint.color))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: tint.color).opacity(0.18)))
                Text("used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// VoiceOver: “Session (5h): 27% used, resets in 3h 24m”.
    private var accessibilityText: String {
        let countdownText = countdown.map { ", \($0)" } ?? ""
        return "\(title): \(percent)% used\(countdownText)"
    }
}

private struct ConnectTokenSheet: View {
    let providerID: ProviderID
    let providerName: String
    @ObservedObject var viewModel: HUDViewModel
    @State private var token = ""
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var tokenFocused: Bool

    private var trimmedToken: String { token.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect \(providerName)")
                .font(.headline)
            Text("Paste the access token to import. It is stored in your login Keychain and never leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Access token", text: $token)
                .textFieldStyle(.roundedBorder)
                .focused($tokenFocused)
                .disabled(viewModel.isConnecting)
                .accessibilityLabel("Access token for \(providerName)")
            if viewModel.isConnecting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(viewModel.isConnecting)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedToken.isEmpty || viewModel.isConnecting)
            }
        }
        .padding(18)
        .frame(width: 320)
        .onAppear { tokenFocused = true }
    }

    private func connect() {
        Task {
            do {
                // Success closes via connectSheetRow = nil in the view model
                // (single dismiss — no explicit dismiss() here).
                try await viewModel.connect(providerID, token: trimmedToken)
            } catch {
                errorMessage = "Couldn't store token (\(error))"
            }
        }
    }
}

/// Window chrome: HUD material below v26, Liquid Glass on macOS 26+.
struct HUDChrome: View {
    var body: some View {
        if #available(macOS 26, *) {
            GlassHUDChrome()
        } else {
            FallbackHUDChrome()
        }
    }
}

@available(macOS 26, *)
private struct GlassHUDChrome: View {
    var body: some View {
        LiquidGlassBackground()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

@available(macOS 26, *)
private struct LiquidGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if let glass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let view = glass.init()
            view.wantsLayer = true
            if let layer = view.layer {
                layer.cornerRadius = 16
                layer.cornerCurve = .continuous
            }
            return view
        }
        return EffectFallbackView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct FallbackHUDChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = EffectFallbackView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class EffectFallbackView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
    }

    required init?(coder: NSCoder) {
        fatalError("not used — views are created in code")
    }
}
