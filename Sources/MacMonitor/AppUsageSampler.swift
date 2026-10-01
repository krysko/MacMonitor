import Darwin
import Foundation

struct AppUsage {
    var name: String
    var cpuPercent: Double
    var memoryBytes: UInt64
}

/// 按应用汇总 CPU 和内存。同一个 `.app` 里的进程会计在一起。
/// CPU 用相邻两次采样的时间差，第一次没有基线时占用率为 0。
final class AppUsageSampler {
    private var previousCPU: [Int32: UInt64] = [:]
    private var names: [Int32: String] = [:]
    private var previousTime: TimeInterval?

    func sample() -> [AppUsage] {
        let now = Date.timeIntervalSinceReferenceDate
        let elapsed = previousTime.map { now - $0 }
        previousTime = now

        let pids = Self.processIDs()
        var nextCPU: [Int32: UInt64] = [:]
        nextCPU.reserveCapacity(pids.count)
        var grouped: [String: (cpu: Double, memory: UInt64)] = [:]

        for pid in pids {
            var info = proc_taskinfo()
            let infoSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, infoSize) == infoSize else { continue }

            let cpuNanoseconds = info.pti_total_user &+ info.pti_total_system
            nextCPU[pid] = cpuNanoseconds
            var cpuPercent = 0.0
            if let elapsed, elapsed > 0, let previous = previousCPU[pid], cpuNanoseconds >= previous {
                cpuPercent = Double(cpuNanoseconds - previous) / (elapsed * 1_000_000_000) * 100
            }

            let name = cachedName(pid: pid)
            let current = grouped[name] ?? (cpu: 0, memory: 0)
            grouped[name] = (current.cpu + cpuPercent, current.memory &+ info.pti_resident_size)
        }

        previousCPU = nextCPU
        names = names.filter { nextCPU[$0.key] != nil }
        return grouped.map { AppUsage(name: $0.key, cpuPercent: $0.value.cpu, memoryBytes: $0.value.memory) }
    }

    private func cachedName(pid: Int32) -> String {
        if let name = names[pid] {
            return name
        }
        let name = Self.applicationName(pid: pid)
        names[pid] = name
        return name
    }

    private static func processIDs() -> [Int32] {
        // 这里的返回值是进程个数，不是字节数。
        let estimated = max(Int(proc_listallpids(nil, 0)), 512)
        var capacity = estimated + 64
        var pids = [Int32](repeating: 0, count: capacity)
        var written = proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.stride))
        if written > capacity {
            capacity = Int(written) + 64
            pids = [Int32](repeating: 0, count: capacity)
            written = proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.stride))
        }
        guard written > 0 else { return [] }
        return pids.prefix(min(capacity, Int(written))).filter { $0 > 0 }
    }

    private static func applicationName(pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let full = String(cString: path)
            if let app = full.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
                return String(app.dropLast(4))
            }
            let executable = (full as NSString).lastPathComponent
            if !executable.isEmpty {
                return executable
            }
        }

        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        let fallback = String(cString: name)
        return fallback.isEmpty ? "进程 \(pid)" : fallback
    }
}
