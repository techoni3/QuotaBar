import Foundation
import Security

/// Stores provider credentials the user explicitly imported ("Connect") in
/// AIMeter's OWN keychain item — never another app's item.
public protocol CredentialVault: Sendable {
    func storeToken(_ token: String, for provider: ProviderID) throws
    /// Returns nil when no token is stored for the provider.
    func fetchToken(for provider: ProviderID) -> String?
    func deleteToken(for provider: ProviderID)
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
}

/// Keychain-backed vault. Imported tokens get
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and never leave the device.
public struct KeychainCredentialVault: CredentialVault {
    /// AIMeter's own keychain service namespace.
    public static let service = "app.aimeter.macos"

    public init() {}

    public func storeToken(_ token: String, for provider: ProviderID) throws {
        let data = Data(token.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
        case errSecItemNotFound:
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: status)
        }
    }

    public func fetchToken(for provider: ProviderID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deleteToken(for provider: ProviderID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Thread-safe in-memory vault for tests and previews.
public final class InMemoryCredentialVault: CredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [ProviderID: String] = [:]

    public init() {}

    public func storeToken(_ token: String, for provider: ProviderID) throws {
        lock.lock(); defer { lock.unlock() }
        tokens[provider] = token
    }

    public func fetchToken(for provider: ProviderID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokens[provider]
    }

    public func deleteToken(for provider: ProviderID) {
        lock.lock(); defer { lock.unlock() }
        tokens[provider] = nil
    }
}
