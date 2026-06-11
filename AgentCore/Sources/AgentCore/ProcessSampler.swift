import Foundation
import Darwin
import MonitorKit

/// Enumerates every process on the system and computes per-process resource
/// usage. Stateful: `sample()` derives CPU% from the delta against the previous
/// call, so call it on a fixed cadence.
///
/// Enumeration uses `sysctl(KERN_PROC_ALL)` (Apple QA1123). This is the key
/// choice: `proc_pidinfo(PROC_PIDTBSDINFO)` is permission-restricted for
/// processes the caller doesn't own, so it silently drops every root/other-user
/// process. `KERN_PROC_ALL` returns pid/ppid/uid/name/status for *all* processes
/// without privilege — matching what `ps` sees.
///
/// Detailed per-process stats (CPU time, footprint, disk IO, threads) come from
/// `proc_pid_rusage`/`proc_pidinfo`, which legitimately return EPERM for
/// root-owned processes from an unprivileged caller. Those rows are still
/// listed, with `statsAvailable == false`.
public final class ProcessSampler {
    private struct CPUTimes { let user: UInt64; let system: UInt64; let start: UInt64 }

    private var previousCPU: [Int32: CPUTimes] = [:]
    private var previousWakeups: [Int32: UInt64] = [:]
    private var previousNanos: UInt64 = 0
    private let currentUID = getuid()

    /// rusage CPU times are in mach time units, which are NOT nanoseconds on
    /// Apple Silicon (timebase 125/3). Convert ticks → ns via numer/denom;
    /// on Intel this is 1/1 (a no-op), so the same code is correct everywhere.
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        if tb.denom == 0 { tb.numer = 1; tb.denom = 1 }
        return tb
    }()

    public init() {}

    /// `helperAvailable` reflects whether a root helper is connected; when it
    /// is, processes the agent can't signal directly (root/other-user) become
    /// killable via the helper, so we mark them killable here.
    public func sample(helperAvailable: Bool = false) -> [ProcessSample] {
        let now = monotonicNanos()
        let wallDeltaNs = previousNanos == 0 ? 0 : now - previousNanos

        let kinfos = Self.kinfoProcs()
        var result: [ProcessSample] = []
        result.reserveCapacity(kinfos.count)

        var nextCPU: [Int32: CPUTimes] = [:]
        var nextWakeups: [Int32: UInt64] = [:]

        for kp in kinfos {
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }

            let uid = kp.kp_eproc.e_ucred.cr_uid
            let ppid = kp.kp_eproc.e_ppid
            let isCurrentUser = (uid == currentUID)
            let status = Self.mapStatus(kp.kp_proc.p_stat)

            var cpuPercent = 0.0
            var footprint: UInt64 = 0
            var diskRead: UInt64 = 0
            var diskWritten: UInt64 = 0
            var energy = 0.0
            var startTime: UInt64 = 0
            var statsAvailable = false

            if let usage = rusage(pid) {
                statsAvailable = true
                footprint = usage.ri_phys_footprint
                diskRead = usage.ri_diskio_bytesread
                diskWritten = usage.ri_diskio_byteswritten
                startTime = usage.ri_proc_start_abstime

                let cpuNow = CPUTimes(user: usage.ri_user_time, system: usage.ri_system_time, start: startTime)
                nextCPU[pid] = cpuNow
                let wakeups = usage.ri_interrupt_wkups &+ usage.ri_pkg_idle_wkups
                nextWakeups[pid] = wakeups

                // Only compute a delta against the SAME process incarnation. If
                // the PID was reused (different start time) or counters somehow
                // went backwards, treat it as a first sighting (0%) instead of
                // wrapping unsigned subtraction into a garbage value.
                if wallDeltaNs > 0,
                   let prev = previousCPU[pid],
                   prev.start == cpuNow.start,
                   cpuNow.user >= prev.user, cpuNow.system >= prev.system {
                    let busyTicks = (cpuNow.user - prev.user) + (cpuNow.system - prev.system)
                    let (scaled, overflow) = busyTicks.multipliedReportingOverflow(by: UInt64(timebase.numer))
                    let busyNs = overflow ? 0 : scaled / UInt64(timebase.denom)
                    cpuPercent = Double(busyNs) / Double(wallDeltaNs) * 100.0

                    // Rough energy estimate: CPU dominates, wakeups add a small
                    // penalty. Deliberately not Apple's private formula.
                    if let prevWake = previousWakeups[pid], wakeups >= prevWake {
                        let wakeupsPerSec = Double(wakeups - prevWake) / (Double(wallDeltaNs) / 1e9)
                        energy = cpuPercent + wakeupsPerSec * 0.01
                    } else {
                        energy = cpuPercent
                    }
                }
            }

            let threads = taskInfo(pid)?.pti_threadnum ?? 0
            let path = executablePath(pid)
            let name = Self.bestName(path: path, comm: kp.kp_proc.p_comm, pid: pid)
            let canKill = pid != getpid() && (isCurrentUser || helperAvailable)

            result.append(ProcessSample(
                pid: pid,
                ppid: ppid,
                name: name,
                executablePath: path,
                uid: uid,
                isCurrentUser: isCurrentUser,
                status: status,
                cpuPercent: cpuPercent,
                memoryFootprint: footprint,
                diskBytesRead: diskRead,
                diskBytesWritten: diskWritten,
                energyImpact: energy,
                threadCount: threads,
                startTime: startTime,
                isSIPProtected: false,          // refined later via csops
                canKill: canKill,
                statsAvailable: statsAvailable
            ))
        }

        previousCPU = nextCPU
        previousWakeups = nextWakeups
        previousNanos = now
        return result
    }

    // MARK: - KERN_PROC_ALL enumeration

    /// Fetches `kinfo_proc` for every process via sysctl. Handles the classic
    /// race where the process table grows between the size query and the fetch
    /// by retrying with the larger size.
    static func kinfoProcs() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]

        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

            let count = size / MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
            let rc = procs.withUnsafeMutableBytes { raw -> Int32 in
                var fetchSize = size
                return sysctl(&mib, 4, raw.baseAddress, &fetchSize, nil, 0)
            }
            if rc == 0 {
                // sysctl updates size to bytes actually written; trim padding.
                return Array(procs.prefix(count))
            }
            if errno != ENOMEM { return [] }   // table grew → retry
        }
        return []
    }

    /// PID list, derived from the same source we enumerate from.
    static func allPIDs() -> [pid_t] {
        kinfoProcs().map { $0.kp_proc.p_pid }.filter { $0 > 0 }
    }

    private static func mapStatus(_ pStat: Int8) -> ProcessStatus {
        // BSD p_stat: SIDL=1, SRUN=2, SSLEEP=3, SSTOP=4, SZOMB=5
        ProcessStatus(rawValue: Int(pStat)) ?? .unknown
    }

    private static func bestName<T>(path: String?, comm: T, pid: pid_t) -> String {
        // Prefer the executable's filename (full, untruncated) when readable;
        // fall back to p_comm (16-char truncated) which KERN_PROC always gives.
        if let path, !path.isEmpty {
            let last = (path as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        let c = cString(comm)
        return c.isEmpty ? "pid \(pid)" : c
    }

    /// Live start time (mach abstime) for a pid, or nil if unreadable. Lets the
    /// server confirm a kill target is still the same incarnation the client saw.
    public func currentStartTime(of pid: pid_t) -> UInt64? {
        rusage(pid)?.ri_proc_start_abstime
    }

    /// Raw cumulative rusage for a pid (used by the root helper to expose stats
    /// for root/other-user processes the agent can't read).
    public func rootStats(of pid: pid_t) -> RootProcStats? {
        guard let u = rusage(pid) else { return nil }
        return RootProcStats(
            cpuUserTime: u.ri_user_time,
            cpuSystemTime: u.ri_system_time,
            memoryFootprint: u.ri_phys_footprint,
            diskBytesRead: u.ri_diskio_bytesread,
            diskBytesWritten: u.ri_diskio_byteswritten,
            startTime: u.ri_proc_start_abstime
        )
    }

    // MARK: - Per-process detail (may EPERM on root/other-user)

    private func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { ptr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, ptr)
            }
        }
        return r == 0 ? usage : nil
    }

    private func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        return r == size ? info : nil
    }

    private func executablePath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (== 4 * MAXPATHLEN) isn't importable into
        // Swift; inline the value.
        let maxSize = 4 * 1024
        var buffer = [CChar](repeating: 0, count: maxSize)
        let r = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard r > 0 else { return nil }
        // proc_pidpath returns the path length (no NUL); decode exactly that.
        return String(decoding: buffer.prefix(Int(r)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
