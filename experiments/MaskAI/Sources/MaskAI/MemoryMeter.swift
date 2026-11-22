import Foundation
import Darwin
import Darwin.Mach

public struct MemorySample: Codable, Equatable, Sendable {
    public let currentRSSBytes: Int64
    public let maximumRSSBytes: Int64
}

public enum MemoryMeter {
    public static func sample() -> MemorySample {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        return MemorySample(currentRSSBytes: status == KERN_SUCCESS ? Int64(info.resident_size) : 0,
                            maximumRSSBytes: Int64(usage.ru_maxrss))
    }
}
