import AIMeterCore
import SwiftUI

/// A quiet, connected-only usage overlay. Provider management lives in Settings.
struct HUDRootView: View {
    @ObservedObject var viewModel: HUDViewModel
    var openSettings: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AIMeter").font(.system(size: 16, weight: .semibold))
                    Text("Usage at a glance")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { viewModel.refreshAll() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh all")
                .accessibilityLabel("Refresh all providers")
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .help("Settings")
                    .accessibilityLabel("Open Settings")
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .help("Close (Esc)")
                    .accessibilityLabel("Close overlay")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)

            if viewModel.visibleRows.isEmpty {
                VStack(spacing: 8) {
                    Text("No connected providers").font(.subheadline)
                    Text("Enable or connect a provider in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top),
                                        GridItem(.flexible(), spacing: 14, alignment: .top)],
                              alignment: .leading, spacing: 14) {
                        ForEach(viewModel.visibleRows) { row in
                            ProviderCard(row: row)
                        }
                    }
                    .padding(1)
                }
            }
            HStack {
                Text("Connected providers")
                Spacer()
                Text("esc to close")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            HUDChrome()
                .overlay(.black.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

private struct ProviderCard: View {
    let row: ProviderRowState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: Self.iconName(for: row.id))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if row.windows.contains(where: { $0.tint == .red || $0.tint == .amber }) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(row.windows.contains(where: { $0.tint == .red }) ? .red : .yellow)
                        .accessibilityLabel("High usage")
                }
            }
            Text(row.planName ?? "Connected")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            VStack(spacing: 12) {
                ForEach(row.windows) { window in
                    UsageBarView(title: window.title, percent: window.percent,
                                 tint: window.tint, countdown: window.countdown)
                }
            }
            Spacer(minLength: 0)
            if let fetched = row.fetchedAt {
                Text("Updated \(fetched.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        }
    }

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
        default: return "chart.bar"
        }
    }
}

private struct UsageBarView: View {
    let title: String
    let percent: Int
    let tint: UsageTint
    let countdown: String?

    private var barColor: Color {
        switch tint {
        case .green: return .green.opacity(0.85)
        case .amber: return .yellow.opacity(0.9)
        case .red: return .red.opacity(0.85)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(percent)%")
                    .monospacedDigit()
                    .foregroundStyle(barColor)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(barColor)
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, percent))) / 100)
                }
            }
            .frame(height: 3)
            if let countdown {
                Text(countdown)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(percent)% used\(countdown.map { ", \($0)" } ?? "")")
    }
}

/// Native behind-window blur keeps the desktop visible without a full-screen scrim.
struct HUDChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 24
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
