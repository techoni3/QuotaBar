import Carbon.HIToolbox
import Foundation
import Testing
@testable import AIMeterCore

struct StatusItemIconStateTests {
    private static func state(results: [ProviderID: ProviderResult],
                              enabled: [ProviderID: Bool] = [:]) -> RefresherState {
        RefresherState(providers: results.keys.map { .init(id: $0, displayName: $0.rawValue) },
                       results: results,
                       enabled: enabled,
                       lastSuccessAt: [:])
    }

    private static func snapshot(percent: Int) -> UsageSnapshot {
        UsageSnapshot(planName: nil, windows: [UsageWindow(kind: .session5h, usedPercent: percent)])
    }

    @Test func noDataIsNormal() {
        #expect(StatusItemState.derive(from: .empty) == .normal)
    }

    @Test func okWindowsAreNormal() {
        let s = Self.state(results: [ProviderID("a"): .success(Self.snapshot(percent: 10))])
        #expect(StatusItemState.derive(from: s) == .normal)
    }

    @Test func boundaryJustUnderAmberIsNormal() {
        let s = Self.state(results: [ProviderID("a"): .success(Self.snapshot(percent: 69))])
        #expect(StatusItemState.derive(from: s) == .normal)
    }

    @Test func seventyIsWarning() {
        let s = Self.state(results: [ProviderID("a"): .success(Self.snapshot(percent: 70))])
        #expect(StatusItemState.derive(from: s) == .warning)
    }

    @Test func ninetyIsCritical() {
        let s = Self.state(results: [ProviderID("a"): .success(Self.snapshot(percent: 90))])
        #expect(StatusItemState.derive(from: s) == .critical)
    }

    @Test func failureIsStale() {
        let s = Self.state(results: [ProviderID("a"): .failure(.unavailable("down"))])
        #expect(StatusItemState.derive(from: s) == .stale)
    }

    @Test func worstWindowAcrossProvidersWins() {
        let s = Self.state(results: [
            ProviderID("a"): .success(Self.snapshot(percent: 60)),
            ProviderID("b"): .success(Self.snapshot(percent: 85)),
        ])
        #expect(StatusItemState.derive(from: s) == .warning)
    }

    @Test func criticalBeatsStale() {
        let s = Self.state(results: [
            ProviderID("a"): .success(Self.snapshot(percent: 95)),
            ProviderID("b"): .failure(.unavailable("down")),
        ])
        #expect(StatusItemState.derive(from: s) == .critical)
    }

    @Test func warningBeatsStale() {
        let s = Self.state(results: [
            ProviderID("a"): .success(Self.snapshot(percent: 75)),
            ProviderID("b"): .failure(.unavailable("down")),
        ])
        #expect(StatusItemState.derive(from: s) == .warning)
    }

    @Test func disabledFailingProviderIsIgnored() {
        let id = ProviderID("off")
        let s = Self.state(results: [id: .failure(.unauthorized(detail: nil))],
                      enabled: [id: false])
        #expect(StatusItemState.derive(from: s) == .normal)
    }

    @Test func disabledProviderWindowsAreIgnored() {
        let id = ProviderID("off")
        let s = Self.state(results: [id: .success(Self.snapshot(percent: 99))],
                      enabled: [id: false])
        #expect(StatusItemState.derive(from: s) == .normal)
    }
}

struct HotkeyChordTests {
    @Test func defaultsAreCmdShiftU() {
        #expect(HotkeyChord.defaults.keyCode == UInt32(kVK_ANSI_U))
        #expect(HotkeyChord.defaults.modifiers == UInt32(cmdKey | shiftKey))
        // Apple convention displays ⌃⌥ ⇧ ⌘ (command last), cf. ⇧⌘Z Redo.
        #expect(HotkeyChord.defaults.displayString == "⇧⌘U")
    }

    @Test func displayOrdersModifiersControlOptionShiftCommand() {
        let chord = HotkeyChord(keyCode: UInt32(kVK_ANSI_K),
                                modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(chord.displayString == "⌃⌥⇧⌘K")
    }

    @Test func plainKeyHasNoSymbols() {
        #expect(HotkeyChord(keyCode: UInt32(kVK_ANSI_J), modifiers: 0).displayString == "J")
        #expect(HotkeyChord(keyCode: UInt32(kVK_ANSI_J), modifiers: 0).hasModifier == false)
    }

    @Test func keyCodeNamesCoverCommonKeys() {
        #expect(KeyCodeNames.name(for: UInt32(kVK_ANSI_A)) == "A")
        #expect(KeyCodeNames.name(for: UInt32(kVK_ANSI_Z)) == "Z")
        #expect(KeyCodeNames.name(for: UInt32(kVK_ANSI_0)) == "0")
        #expect(KeyCodeNames.name(for: UInt32(kVK_ANSI_9)) == "9")
        #expect(KeyCodeNames.name(for: UInt32(kVK_Space)) == "Space")
        #expect(KeyCodeNames.name(for: UInt32(kVK_Return)) == "Return")
        #expect(KeyCodeNames.name(for: UInt32(kVK_Escape)) == "Esc")
        #expect(KeyCodeNames.name(for: 0x7A) == "F1")   // Carbon F1
        #expect(KeyCodeNames.name(for: 0x6F) == "F12")  // Carbon F12
        #expect(KeyCodeNames.name(for: 0x50) == "F19")  // Carbon F19
        #expect(KeyCodeNames.name(for: 0xFF) == "Key 255")
    }
}