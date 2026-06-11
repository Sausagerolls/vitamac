import XCTest
@testable import AgentCore
import MonitorKit

final class SamplerTests: XCTestCase {
    func testEnumeratesManyProcesses() {
        let pids = ProcessSampler.allPIDs()
        // A live macOS system always has well over 100 processes; if we only
        // see a handful we're not actually enumerating (the NSWorkspace trap).
        XCTAssertGreaterThan(pids.count, 50, "expected full process list, got \(pids.count)")
    }

    func testSampleContainsSelf() {
        let sampler = ProcessSampler()
        _ = sampler.sample()
        let procs = sampler.sample()
        let me = procs.first { $0.pid == getpid() }
        XCTAssertNotNil(me, "our own process must appear in the sample")
        XCTAssertTrue(me?.isCurrentUser ?? false)
        XCTAssertTrue(me?.statsAvailable ?? false, "own-process stats must be readable")
        XCTAssertGreaterThan(me?.memoryFootprint ?? 0, 0)
    }

    func testRootProcessesDegradeGracefully() {
        let sampler = ProcessSampler()
        _ = sampler.sample()
        let procs = sampler.sample()
        // launchd (pid 1) is root-owned; we should still list it, just without
        // readable per-process stats from an unprivileged process.
        let launchd = procs.first { $0.pid == 1 }
        XCTAssertNotNil(launchd, "pid 1 must be listed even if stats are restricted")
        XCTAssertFalse(launchd?.isCurrentUser ?? true)
        XCTAssertFalse(launchd?.canKill ?? true, "must not claim we can kill root pid 1")
    }

    func testSystemSampleSane() {
        let sampler = SystemSampler()
        _ = sampler.sample(processCount: 0)
        Thread.sleep(forTimeInterval: 0.3)
        let s = sampler.sample(processCount: 200)
        XCTAssertGreaterThan(s.memory.totalBytes, 1_000_000_000, "should report real total RAM")
        XCTAssertFalse(s.cpu.perCore.isEmpty, "should report per-core CPU")
        XCTAssertGreaterThan(s.uptimeSeconds, 0)
    }
}
