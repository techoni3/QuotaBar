import SwiftUI

/// Root content of the HUD panel. M1 shows only the empty state —
/// provider cards land in M2+.
struct HUDRootView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dial")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("No providers connected yet")
                .font(.headline)
            Text("Connect Claude, Codex and others from Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 320, height: 180)
        .background(HUDChrome())
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