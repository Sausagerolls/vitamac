import Foundation
import IOKit
import MonitorKit

/// Best-effort GPU utilization via IOKit's IOAccelerator PerformanceStatistics
/// (the same source iStat/Stats use). Undocumented keys that vary by GPU; if
/// nothing usable is found it returns nil and the dashboard omits GPU.
public final class GPUSampler {
    public init() {}

    public func sample() -> GPUStats? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: GPUStats?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = read(service) {
                // Pick the busiest accelerator (usually the discrete/active GPU).
                if best == nil || stats.utilizationPercent > best!.utilizationPercent { best = stats }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }

    private func read(_ service: io_object_t) -> GPUStats? {
        guard let raw = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let props = raw as? [String: Any] else { return nil }

        let keys = ["Device Utilization %", "GPU Activity(%)", "GPU Core Utilization"]
        var util: Double?
        for key in keys {
            if let v = props[key] as? Int { util = Double(v); break }
            if let v = props[key] as? Double { util = v; break }
        }
        // "GPU Core Utilization" can be reported in nanoseconds-busy form; clamp.
        guard var u = util else { return nil }
        if u > 100 { u = min(100, u / 10_000_000) }   // crude guard for ns-style values

        var name: String?
        if let raw = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "model" as CFString,
                                                     kCFAllocatorDefault,
                                                     IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) {
            if let data = raw as? Data {
                name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
            } else if let str = raw as? String {
                name = str
            }
        }
        return GPUStats(utilizationPercent: max(0, min(100, u)), name: name)
    }
}
