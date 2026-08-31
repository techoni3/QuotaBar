import Foundation

/// A subscription provider that can produce a usage snapshot.
public protocol AIProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    /// Current health as last known; refresher state usually derives this from
    /// the latest fetch result instead, so a default is fine.
    var status: ProviderStatus { get }
    func fetchUsage() async throws -> UsageSnapshot
}

public extension AIProvider {
    var status: ProviderStatus { .ok }
}
