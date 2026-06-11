import Foundation
import Darwin

/// Converts a fixed-size C char tuple (as imported from Darwin structs) into a
/// Swift String, stopping at the first NUL.
func cString<T>(_ tuple: T) -> String {
    var value = tuple
    return withUnsafePointer(to: &value) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
}

/// Monotonic nanosecond clock, immune to wall-clock adjustments. Used for the
/// time base of CPU-percent deltas.
@inline(__always)
func monotonicNanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
}

extension UInt64 {
    /// Human-readable byte size (e.g. "1.4 GB").
    public var byteString: String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(self)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        return String(format: idx == 0 ? "%.0f %@" : "%.1f %@", value, units[idx])
    }
}
