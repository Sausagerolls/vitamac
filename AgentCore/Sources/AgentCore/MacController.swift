import Foundation
import MonitorKit

/// Performs system power/display actions for the logged-in user. Restart/sleep/
/// shut down go through System Events (no root needed; macOS may prompt once to
/// allow controlling System Events). Display sleep uses pmset.
public struct MacController {
    public init() {}

    public func perform(_ action: MacControlAction) -> (success: Bool, message: String) {
        switch action {
        case .restart:
            return runOsa("tell application \"System Events\" to restart", note: "Restart requested")
        case .shutDown:
            return runOsa("tell application \"System Events\" to shut down", note: "Shut down requested")
        case .sleepSystem:
            return runOsa("tell application \"System Events\" to sleep", note: "Sleep requested")
        case .sleepDisplay:
            return run("/usr/bin/pmset", ["displaysleepnow"], note: "Display off")
        }
    }

    private func runOsa(_ script: String, note: String) -> (Bool, String) {
        run("/usr/bin/osascript", ["-e", script], note: note)
    }

    private func run(_ launchPath: String, _ args: [String], note: String) -> (Bool, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        do {
            try process.run()
            // Don't wait: restart/shut down take the agent down with the system.
            return (true, note)
        } catch {
            return (false, "Failed: \(error.localizedDescription)")
        }
    }
}
