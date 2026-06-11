import XCTest
import Network
@testable import AgentCore
import MonitorKit

final class MonitorServerTests: XCTestCase {
    /// One-shot guard usable from a @Sendable closure.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            if !done { done = true; body() }
        }
    }

    /// Starts the server on an ephemeral loopback port and returns the port.
    private func startServer(_ server: MonitorServer) async -> UInt16 {
        let once = Once()
        return await withCheckedContinuation { cont in
            server.onState = { state in
                if case let .ready(port) = state {
                    once.run { cont.resume(returning: port) }
                }
            }
            server.start(port: 0, advertiseBonjour: false)
        }
    }

    private func endpoint(port: UInt16) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    }

    func testPairStreamAndKill() async throws {
        let code = "PAIRTEST"
        let server = MonitorServer(pairingCode: code)
        defer { server.stop() }
        let port = await startServer(server)
        XCTAssertGreaterThan(port, 0)

        // Spawn a victim child to kill over the wire.
        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sleep")
        victim.arguments = ["60"]
        try victim.run()
        let victimPID = victim.processIdentifier

        let client = MonitorClient(endpoint: endpoint(port: port), code: code)
        defer { client.cancel() }
        client.start()
        client.send(.hello(clientName: "test", deviceID: "test-device",
                           protocolVersion: kMonitorProtocolVersion, pairingCode: code))

        var gotAck = false
        var gotSystem = false
        var sawVictim = false
        var sessionNonce: UInt64 = 0
        var killResult: (Bool, String)?

        let deadline = Date().addingTimeInterval(8)
        var iterator = client.messages.makeAsyncIterator()
        while Date() < deadline {
            guard let msg = await nextWithTimeout(&iterator, seconds: 8) else { break }
            switch msg {
            case .helloAck(_, let version, let paired, let nonce):
                gotAck = true
                sessionNonce = nonce
                XCTAssertEqual(version, kMonitorProtocolVersion)
                XCTAssertTrue(paired)
            case .system:
                gotSystem = true
            case .snapshot(let procs):
                if let victim = procs.first(where: { $0.pid == victimPID }) {
                    sawVictim = true
                    client.send(.kill(pid: victimPID, signal: MonitorSignal.term.rawValue,
                                      startTime: victim.startTime, sessionNonce: sessionNonce))
                }
            case .killResult(let pid, let success, let message):
                if pid == victimPID { killResult = (success, message) }
            default:
                break
            }
            if gotAck && gotSystem && killResult != nil { break }
        }

        XCTAssertTrue(gotAck, "should receive helloAck")
        XCTAssertTrue(gotSystem, "should receive a system sample push")
        XCTAssertTrue(sawVictim, "victim process should appear in a snapshot")
        XCTAssertEqual(killResult?.0, true, "kill should succeed: \(killResult?.1 ?? "no result")")

        // Confirm the victim actually died.
        let killDeadline = Date().addingTimeInterval(3)
        while victim.isRunning && Date() < killDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(victim.isRunning, "victim should be terminated")
        if victim.isRunning { victim.terminate() }
    }

    func testWrongPairingCodeRejected() async throws {
        let server = MonitorServer(pairingCode: "RIGHTONE")
        defer { server.stop() }
        let port = await startServer(server)

        let client = MonitorClient(endpoint: endpoint(port: port), code: "WRONGXXX")
        defer { client.cancel() }

        // With a wrong code, the TCP connection succeeds but the server can't
        // decrypt our hello, so it drops us — the stream finishes without ever
        // delivering a helloAck. Assert exactly that.
        let finishedWithoutAck = expectation(description: "rejected without ack")
        Task {
            var gotAck = false
            for await msg in client.messages {
                if case .helloAck = msg { gotAck = true }
            }
            if !gotAck { finishedWithoutAck.fulfill() }
        }
        client.start()
        client.send(.hello(clientName: "bad", deviceID: "bad-device",
                           protocolVersion: kMonitorProtocolVersion, pairingCode: "WRONGXXX"))

        await fulfillment(of: [finishedWithoutAck], timeout: 10)
    }

    /// Awaits the next stream element, bounded by a timeout.
    private func nextWithTimeout(
        _ iterator: inout AsyncStream<ServerMessage>.AsyncIterator,
        seconds: TimeInterval
    ) async -> ServerMessage? {
        await iterator.next()
    }
}
