import Foundation
import Testing
@testable import AIMeterCore

struct UsageTintTests {
    @Test func boundaries_belowAmber_isGreen() throws {
        #expect(try tintValue(69) == .green)
        #expect(try tintValue(0) == .green)
    }

    @Test func boundary_at70_isAmber() throws {
        #expect(try tintValue(70) == .amber)
    }

    @Test func boundary_at89_isAmber() throws {
        #expect(try tintValue(89) == .amber)
    }

    @Test func boundary_at90_isRed() throws {
        #expect(try tintValue(90) == .red)
        #expect(try tintValue(100) == .red)
    }

    @Test func snapshotWorstTintPicksMostSevere() {
        let green = UsageWindow(kind: .session5h, usedPercent: 10)
        let amber = UsageWindow(kind: .week7d, usedPercent: 75)
        let red = UsageWindow(kind: .month, usedPercent: 95)

        #expect(UsageSnapshot(windows: [green], fetchedAt: Date()).worstTint == .green)
        #expect(UsageSnapshot(windows: [green, amber], fetchedAt: Date()).worstTint == .amber)
        #expect(UsageSnapshot(windows: [green, amber, red], fetchedAt: Date()).worstTint == .red)
        #expect(UsageSnapshot(windows: [], fetchedAt: Date()).worstTint == .green)

    }

    @Test func emptyWindowsWorstTintIsGreen() {
        let snapshot = UsageSnapshot(windows: [], fetchedAt: Date())
        #expect(snapshot.worstTint == .green)
    }

    private func tintValue(_ percent: Int) throws -> UsageTint {
        UsageWindow(kind: .session5h, usedPercent: percent).tint
    }
}