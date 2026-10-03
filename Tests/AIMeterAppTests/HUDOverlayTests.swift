import AppKit
import Testing
@testable import AIMeterApp

@MainActor
struct HUDOverlayTests {
    @Test func centersOverlayInVisibleScreen() {
        let screen = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let frame = HUDOverlayLayout.frame(in: screen, preferredSize: CGSize(width: 660, height: 480))
        #expect(frame == CGRect(x: 390, y: 230, width: 660, height: 480))
    }

    @Test func centersOnSecondaryScreenWithNegativeOrigin() {
        let screen = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let frame = HUDOverlayLayout.frame(in: screen, preferredSize: CGSize(width: 660, height: 480))
        #expect(frame.midX == screen.midX)
        #expect(frame.midY == screen.midY)
        #expect(screen.contains(frame))
    }

    @Test func clampsLargeOverlayToSmallScreen() {
        let screen = CGRect(x: 100, y: 50, width: 600, height: 400)
        let frame = HUDOverlayLayout.frame(in: screen, preferredSize: CGSize(width: 660, height: 900))
        #expect(frame.width == 552)
        #expect(frame.height == 304)
        #expect(screen.contains(frame))
    }

    @Test func overlayIsBorderlessTransparentAndCanReceiveEscape() {
        let panel = HUDPanel()
        #expect(!panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(panel.canBecomeKey)
        #expect(panel.level == .floating)
    }

    @Test func menuBarIconIsRenderableTemplateAtNativeSize() throws {
        let image = StatusItemController.menuBarImage()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        // Sample each bar's center: the icon must have three distinct,
        // increasing ink heights, not an empty image or a solid square.
        let heights = [3, 8, 13].map { x in
            let pixelX = x * bitmap.pixelsWide / 18
            return (0..<bitmap.pixelsHigh).filter { y in
                (bitmap.colorAt(x: pixelX, y: y)?.alphaComponent ?? 0) > 0.5
            }.count
        }
        #expect(heights[0] > 0)
        #expect(heights[0] < heights[1])
        #expect(heights[1] < heights[2])
        #expect(heights[2] < bitmap.pixelsHigh)
    }
}
