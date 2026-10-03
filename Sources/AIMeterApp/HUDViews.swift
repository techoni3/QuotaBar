import AIMeterCore
import SwiftUI

/// Root content of the HUD panel: one card per CONNECTED provider.
struct HUDRootView: View {
    @ObservedObject var viewModel: HUDViewModel
    var openSettings: () -> Void = {}

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
                .accessibilityLabel("Refresh all providers")
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Open Settings")
            }
            .padding(.horizontal, 4)

            if viewModel.visibleRows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)],
                              alignment: .leading,
                              spacing: 12) {
                        ForEach(viewModel.visibleRows) { row in
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
        // Connect/Disconnect moved to Settings → Providers (PER-10); the HUD
        // shows only connected rows and presents no modal sheets.
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No providers connected yet")
                .font(.headline)
            Text("Connect or disconnect providers in Settings.")
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
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("\(row.name), \(statusVoiceOverText)")
            }
            Text(row.planName ?? "Usage")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                statusChip
                Spacer(minLength: 8)
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
                .fixedSize()
            }

            if !row.enabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
            } else {
                // Successful fetch with no windows (e.g. Manual with no plans).
                Text("No plans yet — add them in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let fetched = row.fetchedAt {
                Text("Updated \(fetched.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        )
    }

    /// Per-provider SF Symbol: claude/codex/opencode/antigravity/ollama/copilot/openrouter/manual.
    private static func iconName(for id: ProviderID) -> String {
        switch id.rawValue {
        case "claude": return "sparkles"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "opencode": return "terminal"
        case "antigravity": return "scope"
        case "ollama": return "bolt"
        case "github-copilot", "copilot": return "person.2"
        case "openrouter": return "arrow.left.arrow.right"
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
