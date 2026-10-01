import Darwin

/// CPU 占用率。用相邻两次 `HOST_CPU_LOAD_INFO` 的 tick 差值计算，
/// 第一次采样没有基线，返回 nil。
final class CPUSampler {
    private var previous: host_cpu_load_info?

    func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ticks in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, ticks, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        defer { previous = info }
        guard let previous else { return nil }

        let user = Self.delta(info.cpu_ticks.0, previous.cpu_ticks.0)
        let system = Self.delta(info.cpu_ticks.1, previous.cpu_ticks.1)
        let idle = Self.delta(info.cpu_ticks.2, previous.cpu_ticks.2)
        let nice = Self.delta(info.cpu_ticks.3, previous.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return Double(user + system + nice) / Double(total) * 100
    }

    private static func delta(_ current: natural_t, _ previous: natural_t) -> UInt64 {
        UInt64(current &- previous)
    }
}
