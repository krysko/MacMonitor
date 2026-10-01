import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
    }
}

@main
enum MacMonitorMain {
    static func main() {
        if CommandLine.arguments.contains("--sample") {
            runSample()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// 命令行抽查两次采样，用来确认 CPU、内存、温度都能读到并会变化。
    private static func runSample() {
        let cpu = CPUSampler()
        let memory = MemorySampler()
        let temperature = TemperatureSampler()

        func printOnce(index: Int) {
            let cpuPercent = cpu.sample()
            let memorySample = memory.sample()
            let celsius = temperature.sample()
            let cpuText = cpuPercent.map { String(format: "%.1f", $0) } ?? "nil"
            let memoryText: String
            if let memorySample {
                memoryText = String(
                    format: "%.1f%% used=%llu total=%llu",
                    memorySample.percent,
                    memorySample.usedBytes,
                    memorySample.totalBytes
                )
            } else {
                memoryText = "nil"
            }
            let tempText = celsius.map { String(format: "%.1f", $0) } ?? "nil"
            print("sample\(index) cpu=\(cpuText) memory=\(memoryText) temp=\(tempText)")
            if index == 2 {
                let started = Date()
                let apps = AppUsageSampler()
                _ = apps.sample()
                Thread.sleep(forTimeInterval: 0.4)
                let ranked = apps.sample().sorted { $0.cpuPercent > $1.cpuPercent }
                let elapsed = Date().timeIntervalSince(started) * 1000
                print(String(format: "apps sample %.1f ms count=%d", elapsed, ranked.count))
                for app in ranked.prefix(8) where app.cpuPercent >= 0.5 || app.memoryBytes > 200_000_000 {
                    let megabytes = Double(app.memoryBytes) / 1_048_576
                    print("  \(app.name) cpu=\(String(format: "%.1f", app.cpuPercent)) mem=\(String(format: "%.0f", megabytes))MB")
                }
            }
            if index == 2, celsius == nil {
                let sensors = temperature.readSensors()
                if sensors.isEmpty {
                    print("sensors=(none)")
                } else {
                    for sensor in sensors {
                        print("sensor \(sensor.name)=\(String(format: "%.1f", sensor.celsius))")
                    }
                }
            }
        }

        printOnce(index: 1)
        Thread.sleep(forTimeInterval: 1.1)
        printOnce(index: 2)
    }
}
