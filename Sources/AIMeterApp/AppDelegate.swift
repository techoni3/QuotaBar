import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController()
        statusController.install()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}