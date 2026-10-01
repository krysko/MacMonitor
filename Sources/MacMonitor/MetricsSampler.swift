import Foundation

struct SystemMetrics {
    var cpuPercent: Double?
    var memory: MemorySample?
    var cpuTemperatureC: Double?
    var apps: [AppUsage]
}

final class MetricsSampler {
    var onUpdate: ((SystemMetrics) -> Void)?

    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let temperature = TemperatureSampler()
    private let apps = AppUsageSampler()
    private var timer: Timer?
    private var interval: TimeInterval

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func start() {
        schedule()
        sample()
    }

    func setInterval(_ interval: TimeInterval) {
        self.interval = interval
        schedule()
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        timer.tolerance = min(0.2, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        let metrics = autoreleasepool { () -> SystemMetrics in
            SystemMetrics(
                cpuPercent: cpu.sample(),
                memory: memory.sample(),
                cpuTemperatureC: temperature.sample(),
                apps: apps.sample()
            )
        }
        onUpdate?(metrics)
    }
}
