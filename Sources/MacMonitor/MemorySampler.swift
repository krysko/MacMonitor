import Darwin

struct MemorySample {
    var usedBytes: UInt64
    var totalBytes: UInt64

    var percent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

/// 内存占用，口径与活动监视器的「已使用内存」一致：
/// App 内存 (internal - purgeable) + 联动内存 + 被压缩内存。
final class MemorySampler {
    private let pageSize = UInt64(vm_kernel_page_size)
    private let totalBytes: UInt64 = {
        var total: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &length, nil, 0) == 0 else { return 0 }
        return total
    }()

    func sample() -> MemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { info in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, info, &count)
            }
        }
        guard result == KERN_SUCCESS, totalBytes > 0 else { return nil }

        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let usedPages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return MemorySample(usedBytes: usedPages * pageSize, totalBytes: totalBytes)
    }
}
