import Foundation
import MonitorKit

/// The root-side XPC service. Runs inside the privileged helper daemon, so its
/// ProcessSampler/Killer calls succeed against root/other-user processes.
public final class HelperService: NSObject, MonitorHelperProtocol {
    private let sampler = ProcessSampler()
    private let killer = Killer()

    public override init() { super.init() }

    public func ping(reply: @escaping (String) -> Void) {
        reply("monitor-helper ok (uid \(getuid()))")
    }

    public func kill(pid: Int32, signal: Int32, reply: @escaping (Bool, String) -> Void) {
        let sig = MonitorSignal(rawValue: signal) ?? .term
        let result = killer.kill(pid: pid, signal: sig)
        reply(result.success, result.message)
    }

    public func rusageStats(pid: Int32, reply: @escaping (Data?) -> Void) {
        let stats = sampler.rootStats(of: pid)
        reply(stats.flatMap { try? JSONEncoder().encode($0) })
    }

    public func startTime(pid: Int32, reply: @escaping (UInt64) -> Void) {
        reply(sampler.currentStartTime(of: pid) ?? 0)
    }
}

/// NSXPCListener delegate that accepts agent connections, pinning the peer's
/// code-signing requirement so only our (same-team) agent can talk to root.
public final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    public override init() { super.init() }

    public func listener(_ listener: NSXPCListener,
                         shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: MonitorHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        // Reject any peer not signed by our team.
        newConnection.setCodeSigningRequirement(MonitorHelperInfo.codeSigningRequirement)
        newConnection.resume()
        return true
    }

    /// Builds the listener bound to the LaunchDaemon's Mach service and runs it.
    /// Call from the helper executable's main.
    public static func runForever() -> Never {
        let delegate = HelperListenerDelegate()
        let listener = NSXPCListener(machServiceName: MonitorHelperInfo.machServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.main.run()
        fatalError("helper run loop exited")
    }
}
