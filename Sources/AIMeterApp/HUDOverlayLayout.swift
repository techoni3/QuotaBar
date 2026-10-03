import Foundation

/// Screen-relative placement also handles secondary displays with negative origins.
enum HUDOverlayLayout {
    static func frame(in visibleFrame: CGRect, preferredSize: CGSize) -> CGRect {
        let width = min(preferredSize.width, max(1, visibleFrame.width - 48))
        let height = min(preferredSize.height, max(1, visibleFrame.height * 0.76))
        return CGRect(x: (visibleFrame.midX - width / 2).rounded(),
                      y: (visibleFrame.midY - height / 2).rounded(),
                      width: width, height: height)
    }
}
