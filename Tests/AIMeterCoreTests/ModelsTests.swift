import Foundation
import Testing
@testable import AIMeterCore

struct ModelsTests {
    @Test func providerIDHashesLikeItsValue() {
        let a = ProviderID("claude")
        let b = ProviderID("claude")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a.description == "claude")
    }

    @Test func providerStatusDecodesRoundTrip() throws {
        for status in ProviderStatus.allCases {
            let data = try JSONEncoder().encode(status)
            #expect(try JSONDecoder().decode(ProviderStatus.self, from: data) == status)
        }
    }

    @Test func usageWindowCodableRoundTrip() throws {
        let resets = Date(timeIntervalSince1970: 1_800_000_000)
        let window = UsageWindow(kind: .session5h, usedPercent: 42, resetsAt: resets)
        let data = try JSONEncoder().encode([window])
        let decoded = try JSONDecoder().decode([UsageWindow].self, from: data)
        #expect(decoded == [window])
        #expect(decoded[0].resetsAt == resets)
        #expect(decoded[0].kind == .session5h)
    }

    @Test func usageWindowCodableOptionalResetsAtOmitted() throws {
        let window = UsageWindow(kind: .credits, usedPercent: 0, resetsAt: nil)
        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(UsageWindow.self, from: data)
        #expect(decoded.resetsAt == nil)
    }

    @Test func usageSnapshotCodableRoundTrip() throws {
        let snapshot = UsageSnapshot(
            planName: "Claude Max 20x",
            windows: [
                UsageWindow(kind: .session5h, usedPercent: 27, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)),
                UsageWindow(kind: .week7d, usedPercent: 91, resetsAt: nil),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.planName == "Claude Max 20x")
        #expect(decoded.windows.count == 2)
    }

    @Test func snapshotWithEmptyPlanNameDecodes() throws {
        let snapshot = UsageSnapshot(planName: nil, windows: [], fetchedAt: Date())
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(decoded.planName == nil)
    }
}