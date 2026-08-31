import AIMeterCore
import SwiftUI

/// Root content of the HUD panel: one card per provider.
struct HUDRootView: View {
    @ObservedObject var viewModel: HUDViewModel

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
                    VStack(spacing: 8) {
                        ForEach(viewModel.rows) { row in
                            ProviderCard(row: row,
                                         viewModel: viewModel)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(HUDChrome())
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(row.name)
                    .font(.subheadline.weight(.semibold))
                if let plan = row.planName {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.refresh(row.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(!row.enabled)
                .help("Refresh \(row.name)")
                Toggle("", isOn: Binding(
                    get: { row.enabled },
                    set: { viewModel.setEnabled(row.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }

            if !row.enabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                }
            } else if let error = row.errorText {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.06))
        )
        .sheet(isPresented: Binding(
            get: { viewModel.connectSheetRow == row.id },
            set: { if !$0 { viewModel.connectSheetRow = nil } }
        )) {
            ConnectTokenSheet(providerID: row.id, providerName: row.name, viewModel: viewModel)
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .ok: return .green
        case .unauthorized: return .orange
        case .disabled: return .gray
        case .unavailable: return .red
        case .local: return .blue
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
            .frame(height: 5)
            HStack {
                Text("\(percent)% used")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

private struct ConnectTokenSheet: View {
    let providerID: ProviderID
    let providerName: String
    @ObservedObject var viewModel: HUDViewModel
    @State private var token = ""
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect \(providerName)")
                .font(.headline)
            Text("Paste the access token to import. It is stored in your login Keychain and never leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Access token", text: $token)
                .textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    Task {
                        do {
                            try await viewModel.connect(providerID, token: token.trimmingCharacters(in: .whitespaces))
                            dismiss()
                        } catch {
                            errorMessage = "Couldn't store token (\(String(describing: error)))"
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 320)
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
