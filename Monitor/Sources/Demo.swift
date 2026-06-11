import Foundation
import MonitorKit

/// Simulated data so the app is fully reviewable without the Mac agent
/// (App Review can't run our Developer-ID helper on their LAN). Demo Mode shows
/// realistic, gently-animated vitals + a plausible process list.
enum Demo {
    /// name, executable path, isCurrentUser, base CPU%, memory MB
    private static let seed: [(String, String, Bool, Double, UInt64)] = [
        ("WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/WindowServer", false, 11, 540),
        ("kernel_task", "/kernel", false, 7, 410),
        ("Safari", "/Applications/Safari.app/Contents/MacOS/Safari", true, 24, 1480),
        ("Xcode", "/Applications/Xcode.app/Contents/MacOS/Xcode", true, 33, 2950),
        ("Music", "/System/Applications/Music.app/Contents/MacOS/Music", true, 5, 430),
        ("Mail", "/System/Applications/Mail.app/Contents/MacOS/Mail", true, 3, 280),
        ("Finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", true, 4, 320),
        ("Photos", "/System/Applications/Photos.app/Contents/MacOS/Photos", true, 6, 510),
        ("Messages", "/System/Applications/Messages.app/Contents/MacOS/Messages", true, 2, 240),
        ("Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", true, 8, 190),
        ("Notes", "/System/Applications/Notes.app/Contents/MacOS/Notes", true, 1, 160),
        ("Spotlight", "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight", true, 3, 120),
        ("ControlCenter", "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", true, 2, 90),
        ("coreaudiod", "/usr/sbin/coreaudiod", false, 2, 60),
        ("mds_stores", "/System/Library/Frameworks/CoreServices.framework/mds_stores", false, 5, 140),
        ("launchd", "/sbin/launchd", false, 1, 30),
        ("bluetoothd", "/usr/sbin/bluetoothd", false, 1, 45),
        ("cloudd", "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/cloudd", true, 2, 110),
        ("nsurlsessiond", "/usr/libexec/nsurlsessiond", true, 1, 70),
        ("Slack", "/Applications/Slack.app/Contents/MacOS/Slack", true, 9, 760),
        ("Docker Desktop", "/Applications/Docker.app/Contents/MacOS/Docker Desktop", true, 14, 1180),
        ("Activity Monitor", "/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor", true, 3, 130),
    ]

    static func processes() -> [ProcessSample] {
        seed.enumerated().map { index, s in
            make(name: s.0, path: s.1, currentUser: s.2, cpu: s.3, memMB: s.4, index: index)
        }
    }

    static func jitter(_ procs: [ProcessSample]) -> [ProcessSample] {
        procs.map { p in
            let cpu = max(0, min(165, p.cpuPercent + Double.random(in: -3...3)))
            let mem = UInt64(max(20, Double(p.memoryFootprint) * Double.random(in: 0.97...1.03)))
            return p.with(cpu: cpu, mem: mem)
        }
    }

    static func system(busy: Double) -> SystemSample {
        let total: UInt64 = 16 * 1024 * 1024 * 1024
        let used = UInt64(Double(total) * Double.random(in: 0.58...0.74))
        return SystemSample(
            timestamp: Date(),
            hostName: "Demo Mac",
            cpu: CPUStats(userPercent: busy * 0.68, systemPercent: busy * 0.32,
                          idlePercent: max(0, 100 - busy),
                          perCore: (0..<8).map { _ in Double.random(in: 0...min(100, busy + 40)) }),
            memory: MemoryStats(totalBytes: total, freeBytes: total - used,
                                activeBytes: UInt64(Double(used) * 0.6), inactiveBytes: UInt64(Double(used) * 0.15),
                                wiredBytes: UInt64(Double(used) * 0.15), compressedBytes: UInt64(Double(used) * 0.10),
                                pressurePercent: Double(used) / Double(total) * 100),
            gpu: GPUStats(utilizationPercent: Double.random(in: 18...74), name: "Apple M2"),
            loadAverage: [Double.random(in: 1.4...4.2), 2.3, 1.9],
            uptimeSeconds: 191_000,
            processCount: 318,
            network: NetworkStats(bytesInPerSec: Double.random(in: 2_000...140_000),
                                  bytesOutPerSec: Double.random(in: 800...60_000),
                                  totalBytesIn: 0, totalBytesOut: 0)
        )
    }

    private static func make(name: String, path: String, currentUser: Bool, cpu: Double, memMB: UInt64, index: Int) -> ProcessSample {
        ProcessSample(
            pid: Int32(420 + index * 7), ppid: 1, name: name, executablePath: path,
            uid: currentUser ? 501 : 0, isCurrentUser: currentUser, status: .running,
            cpuPercent: cpu, memoryFootprint: memMB * 1_000_000,
            diskBytesRead: 0, diskBytesWritten: 0, energyImpact: cpu,
            threadCount: Int32.random(in: 2...40), startTime: UInt64(index + 1) * 100_000,
            isSIPProtected: false, canKill: currentUser, statsAvailable: true
        )
    }
}

extension ProcessSample {
    /// Returns a copy with new CPU%/memory (for the demo animation).
    func with(cpu: Double, mem: UInt64) -> ProcessSample {
        ProcessSample(
            pid: pid, ppid: ppid, name: name, executablePath: executablePath,
            uid: uid, isCurrentUser: isCurrentUser, status: status,
            cpuPercent: cpu, memoryFootprint: mem,
            diskBytesRead: diskBytesRead, diskBytesWritten: diskBytesWritten,
            energyImpact: energyImpact, threadCount: threadCount, startTime: startTime,
            isSIPProtected: isSIPProtected, canKill: canKill, statsAvailable: statsAvailable
        )
    }
}
