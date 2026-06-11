import Foundation

/// XPC interface the privileged (root) helper exposes to the agent. Reply
/// payloads stay ObjC-XPC-friendly (primitives + Data).
///
/// The helper runs as root via an SMAppService LaunchDaemon, so it can
/// `proc_pid_rusage` and `kill` root/other-user processes that the unprivileged
/// agent cannot. Both ends pin each other's code-signing requirement.
@objc public protocol MonitorHelperProtocol {
    func ping(reply: @escaping (String) -> Void)
    /// Signal a process the unprivileged agent can't (root/other-user).
    func kill(pid: Int32, signal: Int32, reply: @escaping (Bool, String) -> Void)
    /// JSON-encoded `RootProcStats` for a pid, or nil. (Reserved for future
    /// on-demand stats of root processes; not yet used per-snapshot.)
    func rusageStats(pid: Int32, reply: @escaping (Data?) -> Void)
    func startTime(pid: Int32, reply: @escaping (UInt64) -> Void)
}

public enum MonitorHelperInfo {
    public static let machServiceName = "com.jakewatts.MonitorAgent.helper"
    public static let daemonPlistName = "com.jakewatts.MonitorAgent.helper.plist"
    /// Both ends require the peer to be signed by this team (Developer ID).
    /// Adjust the OU if the signing team changes.
    public static let codeSigningRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"J4UJD4Z33J\""
}

/// Raw cumulative rusage for a root process (deltas computed by the caller).
public struct RootProcStats: Codable, Sendable {
    public let cpuUserTime: UInt64
    public let cpuSystemTime: UInt64
    public let memoryFootprint: UInt64
    public let diskBytesRead: UInt64
    public let diskBytesWritten: UInt64
    public let startTime: UInt64

    public init(cpuUserTime: UInt64, cpuSystemTime: UInt64, memoryFootprint: UInt64,
                diskBytesRead: UInt64, diskBytesWritten: UInt64, startTime: UInt64) {
        self.cpuUserTime = cpuUserTime
        self.cpuSystemTime = cpuSystemTime
        self.memoryFootprint = memoryFootprint
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.startTime = startTime
    }
}
