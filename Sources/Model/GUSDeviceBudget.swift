import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if os(iOS)
import os
#endif

/// What this device can afford for a local model, measured at runtime rather
/// than guessed from the iPhone model name.
public struct GUSDeviceBudget: Sendable, Equatable {
    public enum Fit: String, Sendable, Codable, Comparable {
        /// Estimated peak ≤ 70% of the memory iOS will currently let the app use.
        case comfortable
        /// 70–90%: may work; background apps or long chats can push it over.
        case tight
        /// > 90%: iOS will most likely terminate the app while loading or generating.
        case unlikely

        private var rank: Int { self == .comfortable ? 0 : self == .tight ? 1 : 2 }
        public static func < (lhs: Fit, rhs: Fit) -> Bool { lhs.rank < rhs.rank }
    }

    public let physicalMemory: Int64
    /// The app's current memory ceiling: what it uses now plus what iOS says is still available.
    public let appMemoryLimit: Int64
    public let currentFootprint: Int64

    public init(physicalMemory: Int64, appMemoryLimit: Int64, currentFootprint: Int64) {
        self.physicalMemory = physicalMemory
        self.appMemoryLimit = appMemoryLimit
        self.currentFootprint = currentFootprint
    }

    public static func current() -> GUSDeviceBudget {
        let footprint = currentFootprintBytes()
        let available = availableMemoryBytes()
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        // Simulators/macOS report no jetsam limit; fall back to half of RAM.
        let limit = available > 0 ? available + footprint : physical / 2
        return GUSDeviceBudget(physicalMemory: physical, appMemoryLimit: limit, currentFootprint: footprint)
    }

    public func fit(for manifest: GUSModelManifest, contextTokens: Int = 2048) -> Fit {
        Self.classify(peak: manifest.estimatedPeakBytes(contextTokens: contextTokens), limit: appMemoryLimit)
    }

    static func classify(peak: Int64, limit: Int64) -> Fit {
        guard limit > 0 else { return .unlikely }
        let ratio = Double(peak) / Double(limit)
        if ratio <= 0.70 { return .comfortable }
        if ratio <= 0.90 { return .tight }
        return .unlikely
    }

    /// Bytes iOS will still grant before jetsam (0 where unsupported, e.g. simulator).
    public static func availableMemoryBytes() -> Int64 {
        #if os(iOS) && !targetEnvironment(simulator)
        return Int64(os_proc_available_memory())
        #else
        return 0
        #endif
    }

    /// The footprint jetsam compares against the limit (same number Xcode shows).
    public static func currentFootprintBytes() -> Int64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
        #else
        return 0
        #endif
    }
}
