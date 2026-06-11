import Foundation

/// Coarse process run state, mapped from BSD `p_stat` values.
public enum ProcessStatus: Int, Codable, Sendable, CaseIterable {
    case unknown = 0
    case idle = 1      // SIDL  – being created
    case running = 2   // SRUN
    case sleeping = 3  // SSLEEP
    case stopped = 4   // SSTOP
    case zombie = 5    // SZOMB

    public var label: String {
        switch self {
        case .unknown: return "?"
        case .idle: return "idle"
        case .running: return "running"
        case .sleeping: return "sleeping"
        case .stopped: return "stopped"
        case .zombie: return "zombie"
        }
    }
}

/// A single process's resource snapshot at one sampling instant.
///
/// `cpuPercent` is computed from the delta of CPU time between consecutive
/// samples, so the first sample after a process appears reports 0.
/// `memoryFootprint` mirrors Activity Monitor's "Memory" column
/// (`ri_phys_footprint`), not resident size.
public struct ProcessSample: Codable, Identifiable, Hashable, Sendable {
    public var id: Int32 { pid }

    public let pid: Int32
    public let ppid: Int32
    public let name: String
    public let executablePath: String?
    public let uid: UInt32
    public let isCurrentUser: Bool
    public let status: ProcessStatus

    /// Percent of a single core; can exceed 100 for multi-threaded processes
    /// (Activity Monitor convention).
    public let cpuPercent: Double
    /// Bytes — physical footprint (matches Activity Monitor "Memory").
    public let memoryFootprint: UInt64
    public let diskBytesRead: UInt64
    public let diskBytesWritten: UInt64
    /// Rough estimate (CPU + wakeups). Not Apple's private formula.
    public let energyImpact: Double
    public let threadCount: Int32

    /// Process start time (mach abstime). Identifies a specific incarnation so a
    /// reused PID can't be mistaken for the process the user saw — used to make
    /// CPU-delta math and remote kills safe against PID reuse.
    public let startTime: UInt64

    /// True when we believe killing is unsafe/blocked (system/SIP).
    public let isSIPProtected: Bool
    /// True when the current user is allowed to signal this process.
    public let canKill: Bool
    /// False when per-process stats were unreadable (e.g. EPERM on root procs).
    public let statsAvailable: Bool

    public init(
        pid: Int32,
        ppid: Int32,
        name: String,
        executablePath: String?,
        uid: UInt32,
        isCurrentUser: Bool,
        status: ProcessStatus,
        cpuPercent: Double,
        memoryFootprint: UInt64,
        diskBytesRead: UInt64,
        diskBytesWritten: UInt64,
        energyImpact: Double,
        threadCount: Int32,
        startTime: UInt64,
        isSIPProtected: Bool,
        canKill: Bool,
        statsAvailable: Bool
    ) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.executablePath = executablePath
        self.uid = uid
        self.isCurrentUser = isCurrentUser
        self.status = status
        self.cpuPercent = cpuPercent
        self.memoryFootprint = memoryFootprint
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.energyImpact = energyImpact
        self.threadCount = threadCount
        self.startTime = startTime
        self.isSIPProtected = isSIPProtected
        self.canKill = canKill
        self.statsAvailable = statsAvailable
    }
}

public struct CPUStats: Codable, Hashable, Sendable {
    public let userPercent: Double
    public let systemPercent: Double
    public let idlePercent: Double
    /// Total busy percent (100 − idle) per logical core.
    public let perCore: [Double]

    public var busyPercent: Double { userPercent + systemPercent }

    public init(userPercent: Double, systemPercent: Double, idlePercent: Double, perCore: [Double]) {
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.idlePercent = idlePercent
        self.perCore = perCore
    }
}

public struct MemoryStats: Codable, Hashable, Sendable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    /// Approximate memory pressure as a percent (used / total).
    public let pressurePercent: Double

    public var usedBytes: UInt64 { activeBytes + wiredBytes + compressedBytes }

    public init(totalBytes: UInt64, freeBytes: UInt64, activeBytes: UInt64, inactiveBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64, pressurePercent: Double) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.pressurePercent = pressurePercent
    }
}

public struct GPUStats: Codable, Hashable, Sendable {
    /// Device utilization percent (best-effort via IOAccelerator; may be absent).
    public let utilizationPercent: Double
    public let name: String?

    public init(utilizationPercent: Double, name: String?) {
        self.utilizationPercent = utilizationPercent
        self.name = name
    }
}

public struct NetworkStats: Codable, Hashable, Sendable {
    public let bytesInPerSec: Double
    public let bytesOutPerSec: Double
    public let totalBytesIn: UInt64
    public let totalBytesOut: UInt64

    public init(bytesInPerSec: Double, bytesOutPerSec: Double, totalBytesIn: UInt64, totalBytesOut: UInt64) {
        self.bytesInPerSec = bytesInPerSec
        self.bytesOutPerSec = bytesOutPerSec
        self.totalBytesIn = totalBytesIn
        self.totalBytesOut = totalBytesOut
    }
}

/// System-wide snapshot at one sampling instant.
public struct SystemSample: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let hostName: String
    public let cpu: CPUStats
    public let memory: MemoryStats
    public let gpu: GPUStats?
    public let loadAverage: [Double]   // 1, 5, 15 minute
    public let uptimeSeconds: Double
    public let processCount: Int
    public let network: NetworkStats

    public init(timestamp: Date, hostName: String, cpu: CPUStats, memory: MemoryStats, gpu: GPUStats?, loadAverage: [Double], uptimeSeconds: Double, processCount: Int, network: NetworkStats) {
        self.timestamp = timestamp
        self.hostName = hostName
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.loadAverage = loadAverage
        self.uptimeSeconds = uptimeSeconds
        self.processCount = processCount
        self.network = network
    }
}
