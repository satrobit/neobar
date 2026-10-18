import Darwin
import Foundation
import XCTest

final class ProcessLivenessTests: XCTestCase {

    func testInvalidPIDsAreNeverPassedThroughAsAlive() {
        XCTAssertFalse(ProcessLiveness.isAlive(pid: 0))
        XCTAssertFalse(ProcessLiveness.isAlive(pid: -1))
        XCTAssertFalse(ProcessLiveness.isAlive(pid: -42))
        XCTAssertNil(ProcessLiveness.startTime(pid: 0))
        XCTAssertNil(ProcessLiveness.startTime(pid: -1))
    }

    // MARK: - errno matrix unit tests (pure decision function, issues no syscalls)

    func testInterpretSyscallSuccessIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: 0, errorCode: 0))
    }

    func testInterpretESRCHIsDead() {
        XCTAssertFalse(ProcessLiveness.interpret(result: -1, errorCode: ESRCH))
    }

    func testInterpretEPERMIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: -1, errorCode: EPERM))
    }

    func testInterpretEINTRIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: -1, errorCode: EINTR))
    }

    func testInterpretEINVALIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: -1, errorCode: EINVAL))
    }

    func testInterpretEAGAINIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: -1, errorCode: EAGAIN))
    }

    func testInterpretUnknownErrnoIsAlive() {
        XCTAssertTrue(ProcessLiveness.interpret(result: -1, errorCode: 9999))
    }

    // MARK: - ProcessGenerationCache

    func testGenerationCacheServesOnlyTheSameProcessGeneration() {
        var starts: [pid_t: timeval] = [42: timeval(tv_sec: 100, tv_usec: 5)]
        let cache = ProcessGenerationCache<String>(startTime: { starts[$0] })
        XCTAssertNil(cache.value(for: 42))
        cache.remember("psn", for: 42)
        XCTAssertEqual(cache.value(for: 42), "psn")
        // Same pid, new process: the remembered value is dropped, not served.
        starts[42] = timeval(tv_sec: 100, tv_usec: 6)
        XCTAssertNil(cache.value(for: 42))
        starts[42] = timeval(tv_sec: 100, tv_usec: 5)
        XCTAssertNil(cache.value(for: 42))
        // A dead process remembers nothing.
        cache.remember("dead", for: 7)
        starts[7] = timeval(tv_sec: 1, tv_usec: 0)
        XCTAssertNil(cache.value(for: 7))
    }

    // MARK: - Actual syscall unit tests

    func testCurrentProcessIsAlive() {
        let pid = getpid()
        XCTAssertTrue(ProcessLiveness.isAlive(pid: pid))
    }

    /// Launch /usr/bin/true with posix_spawn, reap it with waitpid, then check liveness --
    /// after the process exits and is reaped the pid no longer exists, and kill(0) returns ESRCH.
    func testReapedChildProcessIsDead() {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/usr/bin/true"),
            nil,
        ]
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }
        let spawnResult = posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, envp)
        XCTAssertEqual(spawnResult, 0, "posix_spawn of /usr/bin/true should succeed")

        var status: Int32 = 0
        let waitResult = waitpid(pid, &status, 0)
        XCTAssertEqual(waitResult, pid, "waitpid should reap the child")

        XCTAssertFalse(ProcessLiveness.isAlive(pid: pid))
    }
}
