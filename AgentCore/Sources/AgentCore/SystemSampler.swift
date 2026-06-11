import Foundation
import Darwin
import MonitorKit

/// Samples system-wide CPU, memory, network, load, and uptime. Stateful for
/// CPU-tick and network-byte deltas, so call on a fixed cadence.
public final class SystemSampler {
    private var previousCoreTicks: [[UInt32]] = []     // [core][state] cumulative ticks
    private var previousNetIn: UInt64 = 0
    private var previousNetOut: UInt64 = 0
    private var previousNanos: UInt64 = 0

    private let pageSize: UInt64
    private let totalMemory: UInt64
    private let hostName: String
    private let gpuSampler = GPUSampler()

    public init() {
        // getpagesize() is a function (concurrency-safe), unlike the
        // vm_kernel_page_size global which Swift 6 rejects as shared mutable state.
        let size = UInt64(getpagesize())
        pageSize = size > 0 ? size : 4096
        totalMemory = SystemSampler.sysctlUInt64("hw.memsize") ?? 0
        hostName = ProcessInfo.processInfo.hostName
    }

    public func sample(processCount: Int) -> SystemSample {
        let now = monotonicNanos()
        let wallDeltaSec = previousNanos == 0 ? 0 : Double(now - previousNanos) / 1e9

        let cpu = sampleCPU()
        let memory = sampleMemory()
        let network = sampleNetwork(wallDeltaSec: wallDeltaSec)

        previousNanos = now

        return SystemSample(
            timestamp: Date(),
            hostName: hostName,
            cpu: cpu,
            memory: memory,
            gpu: gpuSampler.sample(),
            loadAverage: loadAverage(),
            uptimeSeconds: uptime(),
            processCount: processCount,
            network: network
        )
    }

    // MARK: - CPU

    private func sampleCPU() -> CPUStats {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &infoArray,
            &infoCount
        )
        guard result == KERN_SUCCESS, let infoArray else {
            return CPUStats(userPercent: 0, systemPercent: 0, idlePercent: 100, perCore: [])
        }
        defer {
            let sizeBytes = vm_size_t(UInt(infoCount) * UInt(MemoryLayout<integer_t>.stride))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray), sizeBytes)
        }

        let states = Int(CPU_STATE_MAX)   // USER, SYSTEM, IDLE, NICE
        let cores = Int(cpuCount)
        var current: [[UInt32]] = []
        current.reserveCapacity(cores)

        for core in 0..<cores {
            let base = core * states
            var ticks = [UInt32](repeating: 0, count: states)
            for s in 0..<states {
                ticks[s] = UInt32(bitPattern: infoArray[base + s])
            }
            current.append(ticks)
        }

        var perCore: [Double] = []
        perCore.reserveCapacity(cores)
        var totUser = 0.0, totSys = 0.0, totIdle = 0.0, totAll = 0.0

        for core in 0..<cores {
            let cur = current[core]
            let prev = core < previousCoreTicks.count ? previousCoreTicks[core] : [UInt32](repeating: 0, count: states)

            let dUser = Double(cur[Int(CPU_STATE_USER)] &- prev[Int(CPU_STATE_USER)])
            let dSys = Double(cur[Int(CPU_STATE_SYSTEM)] &- prev[Int(CPU_STATE_SYSTEM)])
            let dNice = Double(cur[Int(CPU_STATE_NICE)] &- prev[Int(CPU_STATE_NICE)])
            let dIdle = Double(cur[Int(CPU_STATE_IDLE)] &- prev[Int(CPU_STATE_IDLE)])
            let total = dUser + dSys + dNice + dIdle

            let busy = total > 0 ? (dUser + dSys + dNice) / total * 100.0 : 0
            perCore.append(busy)

            totUser += dUser + dNice
            totSys += dSys
            totIdle += dIdle
            totAll += total
        }

        previousCoreTicks = current

        if totAll <= 0 {
            // First sample: no deltas yet.
            return CPUStats(userPercent: 0, systemPercent: 0, idlePercent: 100, perCore: perCore)
        }
        return CPUStats(
            userPercent: totUser / totAll * 100.0,
            systemPercent: totSys / totAll * 100.0,
            idlePercent: totIdle / totAll * 100.0,
            perCore: perCore
        )
    }

    // MARK: - Memory

    private func sampleMemory() -> MemoryStats {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ptr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemoryStats(totalBytes: totalMemory, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0, compressedBytes: 0, pressurePercent: 0)
        }

        let free = UInt64(stats.free_count) * pageSize
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        let used = active + wired + compressed
        let pressure = totalMemory > 0 ? Double(used) / Double(totalMemory) * 100.0 : 0

        return MemoryStats(
            totalBytes: totalMemory,
            freeBytes: free,
            activeBytes: active,
            inactiveBytes: inactive,
            wiredBytes: wired,
            compressedBytes: compressed,
            pressurePercent: pressure
        )
    }

    // MARK: - Network

    private func sampleNetwork(wallDeltaSec: Double) -> NetworkStats {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = ptr {
                let addr = cur.pointee.ifa_addr
                if let addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                    let name = String(cString: cur.pointee.ifa_name)
                    if !name.hasPrefix("lo") {   // skip loopback
                        if let dataPtr = cur.pointee.ifa_data {
                            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                            totalIn &+= UInt64(data.ifi_ibytes)
                            totalOut &+= UInt64(data.ifi_obytes)
                        }
                    }
                }
                ptr = cur.pointee.ifa_next
            }
            freeifaddrs(first)
        }

        var inPerSec = 0.0
        var outPerSec = 0.0
        if wallDeltaSec > 0 && previousNetIn > 0 {
            inPerSec = Double(totalIn &- previousNetIn) / wallDeltaSec
            outPerSec = Double(totalOut &- previousNetOut) / wallDeltaSec
            if inPerSec < 0 { inPerSec = 0 }
            if outPerSec < 0 { outPerSec = 0 }
        }
        previousNetIn = totalIn
        previousNetOut = totalOut

        return NetworkStats(bytesInPerSec: inPerSec, bytesOutPerSec: outPerSec, totalBytesIn: totalIn, totalBytesOut: totalOut)
    }

    // MARK: - Load / uptime / sysctl helpers

    private func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let n = getloadavg(&loads, 3)
        return n == 3 ? loads : [0, 0, 0]
    }

    private func uptime() -> Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        let boot = Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
        return Date().timeIntervalSince1970 - boot
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.stride
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}
