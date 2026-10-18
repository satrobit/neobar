import XCTest
@testable import NeoBar

final class ProcessEnvironmentScrubTests: XCTestCase {
    /// The set of variables actually observed on the owner's machine for the WeChat process (terminal + Claude Code); all must be scrubbed.
    func testTerminalAndAgentVariablesAreUnset() {
        let env = [
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "SHELL": "/bin/zsh",
            "TERM_PROGRAM": "ghostty", "TERM": "xterm-ghostty",
            "CLAUDE_CODE_SESSION_ID": "x", "CLAUDE_PID": "1",
        ]
        XCTAssertEqual(ProcessEnvironmentScrub.keysToUnset(in: env),
                       ["CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "LANG", "LC_ALL", "SHELL", "TERM", "TERM_PROGRAM"])
    }

    /// Our own switches, system-provided variables, and path-like variables are never touched.
    func testOwnSwitchesAndSystemVariablesSurvive() {
        let env = [
            "DOCK_LAUNCH_TRACE": "1", "DOCK_INVENTORY_LOG": "1",
            "PATH": "/usr/bin", "HOME": "/Users/x", "TMPDIR": "/tmp",
            "__CF_USER_TEXT_ENCODING": "0x1F5:0x19:0x34", "__CFBundleIdentifier": "app.neobar.NeoBar",
        ]
        XCTAssertTrue(ProcessEnvironmentScrub.keysToUnset(in: env).isEmpty)
    }

    /// A normal environment launched from Launchpad / a login item: nothing is scrubbed, zero impact.
    func testCleanEnvironmentIsNoOp() {
        XCTAssertTrue(ProcessEnvironmentScrub.keysToUnset(in: [:]).isEmpty)
    }

    /// Actually calls `unsetenv`: set a fake CLAUDE_ variable, then apply; it must be gone from the process environment.
    func testApplyUnsetsFromProcessEnvironment() {
        setenv("CLAUDE_SCRUB_PROBE", "1", 1)
        XCTAssertEqual(ProcessInfo.processInfo.environment["CLAUDE_SCRUB_PROBE"], "1")
        ProcessEnvironmentScrub.apply()
        XCTAssertNil(ProcessInfo.processInfo.environment["CLAUDE_SCRUB_PROBE"])
    }
}
