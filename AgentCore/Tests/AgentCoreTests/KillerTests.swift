import XCTest
@testable import AgentCore
import MonitorKit

final class KillerTests: XCTestCase {
    /// Spawns a real child process, then kills it through Killer and confirms
    /// it actually dies.
    func testKillsOwnChildProcess() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        let pid = proc.processIdentifier
        XCTAssertGreaterThan(pid, 0)

        let result = Killer().kill(pid: pid, signal: .term)
        XCTAssertTrue(result.success, "expected to signal own child: \(result.message)")

        // Give it a moment to die, then confirm.
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(proc.isRunning, "child should have terminated")
    }

    /// Signaling root-owned pid 1 (launchd) from an unprivileged process must
    /// fail with a clear permission message — and must NOT deliver the signal.
    func testCannotKillRootProcess() {
        let result = Killer().kill(pid: 1, signal: .term)
        XCTAssertFalse(result.success)
        XCTAssertTrue(
            result.message.lowercased().contains("permission"),
            "expected a permission-denied message, got: \(result.message)"
        )
    }

    func testRefusesToSignalSelf() {
        let result = Killer().kill(pid: getpid(), signal: .kill)
        XCTAssertFalse(result.success)
    }
}
