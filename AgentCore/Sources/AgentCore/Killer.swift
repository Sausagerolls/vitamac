import Foundation
import Darwin
import AppKit
import MonitorKit

/// Terminates processes on behalf of the user. Works from a non-sandboxed
/// Developer-ID app without root for same-user processes; signaling
/// other-user/root processes fails with EPERM (surfaced as a clear message).
public struct Killer {
    public struct Result: Sendable {
        public let success: Bool
        public let message: String
    }

    public init() {}

    /// Sends `signal` to `pid`. For SIGTERM on a GUI app we prefer AppKit's
    /// graceful terminate; everything else uses the kill() syscall directly.
    public func kill(pid: pid_t, signal: MonitorSignal) -> Result {
        guard pid > 0 else { return Result(success: false, message: "Invalid pid \(pid)") }
        guard pid != getpid() else { return Result(success: false, message: "Refusing to signal self") }

        // Prefer AppKit for GUI apps on a graceful quit — it routes through the
        // app's normal termination, letting it save state.
        if signal == .term, let app = NSRunningApplication(processIdentifier: pid) {
            let ok = app.terminate()
            if ok {
                return Result(success: true, message: "Requested quit of \(app.localizedName ?? "pid \(pid)")")
            }
            // Fall through to syscall if AppKit declined (e.g. sandbox/other app).
        }

        let rc = Darwin.kill(pid, signal.rawValue)
        if rc == 0 {
            return Result(success: true, message: "Sent \(signal.label) to pid \(pid)")
        }
        return Result(success: false, message: errorMessage(for: errno, pid: pid))
    }

    /// AppKit force-quit for a GUI app (SIGKILL-equivalent for apps).
    public func forceTerminateApp(pid: pid_t) -> Result {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return Result(success: false, message: "pid \(pid) is not a GUI application")
        }
        let ok = app.forceTerminate()
        return Result(
            success: ok,
            message: ok ? "Force-terminated \(app.localizedName ?? "pid \(pid)")"
                        : "forceTerminate refused (sandboxed or already gone)"
        )
    }

    private func errorMessage(for err: Int32, pid: pid_t) -> String {
        switch err {
        case EPERM:
            return "Permission denied for pid \(pid) — owned by another user or root (needs privileged helper)"
        case ESRCH:
            return "pid \(pid) no longer exists"
        case EINVAL:
            return "Invalid signal for pid \(pid)"
        default:
            return "kill(pid \(pid)) failed: \(String(cString: strerror(err)))"
        }
    }
}
