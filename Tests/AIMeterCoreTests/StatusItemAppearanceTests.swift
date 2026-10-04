import AppKit
import Testing
@testable import AIMeterCore

@MainActor
struct StatusItemAppearanceTests {
    @Test(arguments: [StatusItemState.normal, .stale])
    func neutralIconHasContrastInLightAndDarkMode(_ state: StatusItemState) throws {
        let color = try #require(state.statusItemColor)
        let light = try resolved(color, appearance: .aqua, background: 0.96)
        let dark = try resolved(color, appearance: .darkAqua, background: 0.08)

        // Account for the semantic color's alpha against a menu-bar backdrop.
        #expect(contrast(light, background: 0.96) >= 3)
        #expect(contrast(dark, background: 0.08) >= 3)
        #expect(dark > light)
    }

    private func resolved(_ color: NSColor, appearance name: NSAppearance.Name,
                          background: CGFloat) throws -> CGFloat {
        let appearance = try #require(NSAppearance(named: name))
        var foreground: CGFloat?
        appearance.performAsCurrentDrawingAppearance {
            if let rgb = color.usingColorSpace(.deviceRGB) {
                let brightness = 0.2126 * rgb.redComponent
                    + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
                foreground = brightness * rgb.alphaComponent + background * (1 - rgb.alphaComponent)
            }
        }
        return try #require(foreground)
    }

    private func contrast(_ foreground: CGFloat, background: CGFloat) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let a = linear(foreground), b = linear(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
