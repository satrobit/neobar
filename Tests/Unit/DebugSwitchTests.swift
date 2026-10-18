import XCTest

/// Polarity lock for `DebugSwitch`: the `!= "0"` / `== "1"` semantics at each call site before the migration must be preserved word for word.
final class DebugSwitchTests: XCTestCase {
    func testKillSwitchIsOnUnlessExplicitlyZero() {
        let s = DebugSwitch.eventAxAsync
        XCTAssertEqual(s.kind, .killSwitch)
        XCTAssertTrue(s.isEnabled(in: [:]))
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "1"]))
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "false"]), "只有字面 \"0\" 才关，与迁移前一致")
        XCTAssertFalse(s.isEnabled(in: [s.rawValue: "0"]))
    }

    func testTraceIsOffUnlessExplicitlyOne() {
        let s = DebugSwitch.hoverTrace
        XCTAssertEqual(s.kind, .trace)
        XCTAssertFalse(s.isEnabled(in: [:]))
        XCTAssertFalse(s.isEnabled(in: [s.rawValue: "true"]), "只有字面 \"1\" 才开，与迁移前一致")
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "1"]))
    }

    func testAcceptedBalancedInsetsAreEnabledWithoutLaunchOverrides() {
        let control = DebugSwitch.stripBalancedInsets
        XCTAssertTrue(control.isEnabled(in: [:]))
        XCTAssertTrue(control.isEnabled(in: [control.rawValue: "1"]))
        XCTAssertFalse(control.isEnabled(in: [control.rawValue: "0"]))
    }

    func testValueReturnsRawStringOrNil() {
        let s = DebugSwitch.reconcileAxTimeoutMs
        XCTAssertEqual(s.kind, .value)
        XCTAssertNil(s.value(in: [:]))
        XCTAssertEqual(s.value(in: [s.rawValue: " 250 "]), " 250 ")
    }

    func testEveryCaseHasDockPrefixAndUniqueRawValue() {
        let raws = DebugSwitch.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        for raw in raws { XCTAssertTrue(raw.hasPrefix("DOCK_"), raw) }
    }
}
