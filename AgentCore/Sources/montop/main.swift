import Foundation
import Network
import AgentCore
import MonitorKit

// montop — CLI validation harness for the Sampler core (Phase 1).
//
// Usage:
//   montop            print one snapshot (samples 1s apart for CPU deltas)
//   montop --watch    refresh every second until Ctrl-C
//   montop --top N    show top N rows (default 25)

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: flush each print immediately

/// One-shot guard usable from a @Sendable closure.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !done { done = true; body() }
    }
}

let args = CommandLine.arguments

// --selftest: run the full server↔client flow in one process (loopback, no
// Bonjour) with step-by-step prints and a hard watchdog. Validates the
// transport end-to-end outside the XCTest harness.
if args.contains("--selftest") {
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
        print("TIMEOUT — selftest did not complete in 15s"); exit(1)
    }
    let sema = DispatchSemaphore(value: 0)
    Task.detached {   // detached: must not inherit the main actor, which sema.wait() blocks
        let code = "SELFTEST"
        let server = MonitorServer(pairingCode: code)
        let once = Once()
        let port: UInt16 = await withCheckedContinuation { cont in
            server.onState = { state in
                print("[server] \(state)")
                if case let .ready(p) = state {
                    once.run { cont.resume(returning: p) }
                }
            }
            server.start(port: 0, advertiseBonjour: false)
        }
        print("[selftest] server ready on port \(port)")

        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sleep")
        victim.arguments = ["60"]
        try? victim.run()
        let vpid = victim.processIdentifier
        print("[selftest] spawned victim pid \(vpid)")

        let client = MonitorClient(
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
            code: code
        )
        client.onState = { print("[client] \($0)") }
        client.onWaiting = { print("[client] WAITING ERROR: \($0)") }
        client.start()
        client.send(.hello(clientName: "selftest", deviceID: "selftest-device",
                           protocolVersion: kMonitorProtocolVersion, pairingCode: code))

        var sentKill = false
        var sessionNonce: UInt64 = 0
        for await msg in client.messages {
            switch msg {
            case let .helloAck(name, version, paired, nonce):
                sessionNonce = nonce
                print("[selftest] ACK from \(name) v\(version) paired=\(paired)")
            case let .system(s):
                print(String(format: "[selftest] system: CPU %.0f%% mem %.0f%% procs %d",
                             s.cpu.busyPercent, s.memory.pressurePercent, s.processCount))
            case let .snapshot(procs):
                print("[selftest] snapshot: \(procs.count) procs")
                if !sentKill, let victim = procs.first(where: { $0.pid == vpid }) {
                    sentKill = true
                    print("[selftest] sending kill for victim \(vpid)")
                    client.send(.kill(pid: vpid, signal: MonitorSignal.term.rawValue,
                                      startTime: victim.startTime, sessionNonce: sessionNonce))
                }
            case let .killResult(pid, ok, message):
                print("[selftest] killResult pid \(pid) ok=\(ok): \(message)")
                if ok && pid == vpid { print("SELFTEST PASS"); exit(0) }
                else { print("SELFTEST FAIL"); exit(1) }
            default:
                break
            }
        }
        print("[selftest] stream ended unexpectedly"); exit(1)
    }
    sema.wait()
}

// --serve [CODE]: start the network server and print state transitions, so we
// can validate the listener/Bonjour/TLS path outside the test harness.
if let i = args.firstIndex(of: "--serve") {
    let code = (i + 1 < args.count && !args[i + 1].hasPrefix("--")) ? args[i + 1] : "TESTCODE"
    let bonjour = !args.contains("--no-bonjour")
    let server = MonitorServer(pairingCode: code)
    print("Starting server (code=\(code), bonjour=\(bonjour))…")
    server.onState = { state in
        switch state {
        case .stopped: print("[state] stopped")
        case .starting: print("[state] starting")
        case .ready(let port): print("[state] READY on port \(port)")
        case .failed(let msg): print("[state] FAILED: \(msg)")
        }
    }
    server.onClientCountChanged = { print("[clients] \($0) connected") }
    server.start(advertiseBonjour: bonjour)
    RunLoop.main.run()
    exit(0)
}

let watch = args.contains("--watch")
let topN: Int = {
    if let i = args.firstIndex(of: "--top"), i + 1 < args.count, let n = Int(args[i + 1]) { return n }
    return 25
}()

let processSampler = ProcessSampler()
let systemSampler = SystemSampler()

@MainActor
func render() {
    // Two samples a second apart so CPU% reflects a real interval.
    _ = processSampler.sample()
    _ = systemSampler.sample(processCount: 0)
    Thread.sleep(forTimeInterval: 1.0)

    let procs = processSampler.sample()
    let sys = systemSampler.sample(processCount: procs.count)

    if watch { print("\u{1B}[2J\u{1B}[H", terminator: "") }   // clear screen

    let unreadable = procs.filter { !$0.statsAvailable }.count
    let killable = procs.filter { $0.canKill }.count

    print("Host: \(sys.hostName)   Uptime: \(Int(sys.uptimeSeconds / 3600))h   Load: " +
          sys.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " "))
    print(String(format: "CPU:  user %.1f%%  sys %.1f%%  idle %.1f%%   (%d cores)",
                 sys.cpu.userPercent, sys.cpu.systemPercent, sys.cpu.idlePercent, sys.cpu.perCore.count))
    print("Mem:  \(sys.memory.usedBytes.byteString) used / \(sys.memory.totalBytes.byteString)" +
          String(format: "  (%.0f%%)   wired %@  compressed %@",
                 sys.memory.pressurePercent, sys.memory.wiredBytes.byteString, sys.memory.compressedBytes.byteString))
    print(String(format: "Net:  ↓ %@/s   ↑ %@/s", UInt64(sys.network.bytesInPerSec).byteString, UInt64(sys.network.bytesOutPerSec).byteString))
    print("Procs: \(procs.count) total   \(killable) killable (you)   \(unreadable) stats-restricted (root/other-user)")
    print(String(repeating: "─", count: 86))
    print(String(format: "%6@  %6@  %-26@  %9@  %5@  %-9@  %@",
                 "PID" as NSString, "CPU%" as NSString, "NAME" as NSString,
                 "MEM" as NSString, "THR" as NSString, "STATE" as NSString, "USER" as NSString))

    let sorted = procs.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(topN)
    for p in sorted {
        let mem = p.statsAvailable ? p.memoryFootprint.byteString : "—"
        let cpu = p.statsAvailable ? String(format: "%.1f", p.cpuPercent) : "—"
        let owner = p.isCurrentUser ? "you" : "uid \(p.uid)"
        print(String(format: "%6d  %6@  %-26@  %9@  %5d  %-9@  %@",
                     p.pid, cpu as NSString, String(p.name.prefix(26)) as NSString,
                     mem as NSString, p.threadCount, p.status.label as NSString, owner as NSString))
    }
}

if watch {
    signal(SIGINT) { _ in print("\n"); exit(0) }
    while true { render() }
} else {
    render()
}
