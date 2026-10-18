import XCTest
@testable import NeoBar

final class MinimizeHandoffTargetTests: XCTestCase {
    private func record(_ id: String, pid: Int32, wid: CGWindowID?, status: WindowStatus = .inactive) -> WindowRecord {
        var r = WindowRecord(
            id: WindowID(rawValue: id), appID: AppID(rawValue: "app-\(pid)"), pid: pid,
            bundleIdentifier: nil, title: "T", bounds: nil, status: status
        )
        r.cgWindowID = wid
        return r
    }

    private func snapshot(_ records: [WindowRecord]) -> DockSnapshot {
        DockSnapshot(
            windows: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }),
            orderedWindowIDs: records.map(\.id)
        )
    }

    private func z(_ pairs: [(Int32, CGWindowID)]) -> [MinimizeHandoffTarget.ZOrderedWindow] {
        pairs.map { .init(pid: $0.0, cgWindowID: $0.1) }
    }

    /// B1 > A > B2: what lies underneath is another app -> hand off to A (pid + its window).
    func testOtherAppDirectlyBeneathIsSwitchedTo() {
        let b1 = record("b1", pid: 2, wid: 21, status: .active)
        let a = record("a", pid: 1, wid: 11)
        let b2 = record("b2", pid: 2, wid: 22)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(2, 21), (1, 11), (2, 22)]), target: b1, snapshot: snapshot([b1, a, b2]))
        XCTAssertEqual(verdict, .switchTo(pid: 1, cgWindowID: 11, windowID: WindowID(rawValue: "a")))
    }

    /// B1 > B2 > A: what lies immediately underneath is a sibling -> no handoff, let AppKit natively promote B2.
    func testSiblingDirectlyBeneathTakesOver() {
        let b1 = record("b1", pid: 2, wid: 21, status: .active)
        let b2 = record("b2", pid: 2, wid: 22)
        let a = record("a", pid: 1, wid: 11)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(2, 21), (2, 22), (1, 11)]), target: b1, snapshot: snapshot([b1, b2, a]))
        XCTAssertEqual(verdict, .siblingTakesOver(windowID: WindowID(rawValue: "b2")))
    }

    /// A window not absorbed by the strip lies in between (not in the snapshot) -> skip it and take the next one.
    func testUnadmittedWindowsAreSkipped() {
        let b1 = record("b1", pid: 2, wid: 21, status: .active)
        let a = record("a", pid: 1, wid: 11)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(2, 21), (9, 99), (1, 11)]), target: b1, snapshot: snapshot([b1, a]))
        XCTAssertEqual(verdict, .switchTo(pid: 1, cgWindowID: 11, windowID: WindowID(rawValue: "a")))
    }

    /// Entries above the target (other windows floating above it) are not candidates.
    func testEntriesAboveTargetAreIgnored() {
        let b1 = record("b1", pid: 2, wid: 21, status: .active)
        let c = record("c", pid: 3, wid: 31)
        let a = record("a", pid: 1, wid: 11)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(3, 31), (2, 21), (1, 11)]), target: b1, snapshot: snapshot([b1, c, a]))
        XCTAssertEqual(verdict, .switchTo(pid: 1, cgWindowID: 11, windowID: WindowID(rawValue: "a")))
    }

    /// The target is not in the CG list (cgWindowID unknown) -> scan from the start.
    func testTargetMissingFromZOrderScansFromTop() {
        let b1 = record("b1", pid: 2, wid: nil, status: .active)
        let a = record("a", pid: 1, wid: 11)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(1, 11)]), target: b1, snapshot: snapshot([b1, a]))
        XCTAssertEqual(verdict, .switchTo(pid: 1, cgWindowID: 11, windowID: WindowID(rawValue: "a")))
    }

    /// No on-screen window to hand off to -> none (the fallback path is decided by the caller).
    func testNoCandidateYieldsNone() {
        let b1 = record("b1", pid: 2, wid: 21, status: .active)
        let hidden = record("h", pid: 1, wid: 11, status: .hidden)
        let verdict = MinimizeHandoffTarget.select(
            zOrder: z([(2, 21), (1, 11)]), target: b1, snapshot: snapshot([b1, hidden]))
        XCTAssertEqual(verdict, .none)
        XCTAssertEqual(MinimizeHandoffTarget.select(zOrder: [], target: b1, snapshot: snapshot([b1])), .none)
    }
}
