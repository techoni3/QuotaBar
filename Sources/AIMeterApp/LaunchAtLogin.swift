import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+; the app targets 15+ so the API
/// is always present). The toggle state comes from the service status itself,
/// not a UserDefaults mirror.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        if #available(macOS 13, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Registration may need System Settings approval on some setups.
    static var requiresApproval: Bool {
        if #available(macOS 13, *) {
            return SMAppService.mainApp.status == .requiresApproval
        }
        return false
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13, *) else {
            throw LaunchAtLoginError.unsupported
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw LaunchAtLoginError.failed(error.localizedDescription)
        }
    }
}

enum LaunchAtLoginError: Error, Equatable {
    case unsupported
    case failed(String)

    var displayText: String {
        switch self {
        case .unsupported:
            return "Launch at login requires macOS 13 or newer."
        case .failed(let detail):
            return "Couldn't update the login item: \(detail)"
        }
    }
}