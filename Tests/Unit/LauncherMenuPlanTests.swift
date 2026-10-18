import XCTest
@testable import NeoBar

final class LauncherMenuPlanTests: XCTestCase {

    func testRunningNotHiddenShowsHideAndQuit() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: true, isHidden: false, hasWindows: false, hasMembership: false)
        XCTAssertEqual(kinds, [.recentDocuments, .hide, .quit])
    }

    func testRunningHiddenShowsShowAndQuit() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: true, isHidden: true, hasWindows: false, hasMembership: false)
        XCTAssertEqual(kinds, [.recentDocuments, .show, .quit])
    }

    func testNotRunningNoMembershipShowsOpenOnly() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: false, isHidden: false, hasWindows: false, hasMembership: false)
        XCTAssertEqual(kinds, [.open])
    }

    func testNotRunningWithMembershipShowsOpenRecentAndMembership() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: false, isHidden: false, hasWindows: false, hasMembership: true)
        XCTAssertEqual(kinds, [.open, .recentDocuments, .membership])
    }

    func testRunningWithMembershipShowsAll() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: true, isHidden: false, hasWindows: false, hasMembership: true)
        XCTAssertEqual(kinds, [.recentDocuments, .hide, .membership, .quit])
    }

    /// Window list (2026-08-24): placed first when running with real windows; when not running it doesn't appear even if a window is falsely reported.
    func testRunningWithWindowsStartsWithWindowList() {
        let kinds = LauncherMenuPlan.itemKinds(isRunning: true, isHidden: false, hasWindows: true, hasMembership: true)
        XCTAssertEqual(kinds, [.windowList, .recentDocuments, .hide, .membership, .quit])

        let notRunning = LauncherMenuPlan.itemKinds(isRunning: false, isHidden: false, hasWindows: true, hasMembership: false)
        XCTAssertFalse(notRunning.contains(.windowList), "未运行的显示态不该列窗口（显示区判据优先）")
    }

    /// Quit is always the last item: member items used to be placed after Quit, so "Quit" landed third from last in the kept icon's menu.
    func testQuitIsAlwaysLastWhenPresent() {
        for isRunning in [true, false] {
            for isHidden in [true, false] {
                for hasWindows in [true, false] {
                    for hasMembership in [true, false] {
                        let kinds = LauncherMenuPlan.itemKinds(isRunning: isRunning,
                                                               isHidden: isHidden,
                                                               hasWindows: hasWindows,
                                                               hasMembership: hasMembership)
                        guard kinds.contains(.quit) else { continue }
                        XCTAssertEqual(kinds.last, .quit,
                                       "running=\(isRunning) hidden=\(isHidden) windows=\(hasWindows) membership=\(hasMembership) → \(kinds)")
                    }
                }
            }
        }
    }

}
