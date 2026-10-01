import AppKit

final class StatusBarController: NSObject {
    static let intervals: [TimeInterval] = [0.5, 1, 2, 5, 10]
    private static let defaultsKey = "sampleInterval"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let cpuItem = NSMenuItem(title: "CPU：--", action: nil, keyEquivalent: "")
    private let memoryItem = NSMenuItem(title: "内存：--", action: nil, keyEquivalent: "")
    private let temperatureItem = NSMenuItem(title: "温度：--", action: nil, keyEquivalent: "")
    private let intervalMenuItem = NSMenuItem(title: "刷新频率", action: nil, keyEquivalent: "")
    private var intervalItems: [NSMenuItem] = []
    private let sampler: MetricsSampler
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private var menuOpen = false
    private var latest: SystemMetrics?
    private var appliedSignature: String?

    override init() {
        let interval = Self.savedInterval()
        sampler = MetricsSampler(interval: interval)
        super.init()

        cpuItem.isEnabled = false
        memoryItem.isEnabled = false
        temperatureItem.isEnabled = false

        let menu = NSMenu()
        menu.addItem(cpuItem)
        menu.addItem(memoryItem)
        menu.addItem(temperatureItem)
        menu.addItem(.separator())

        let intervalMenu = NSMenu()
        for candidate in Self.intervals {
            let item = NSMenuItem(
                title: Self.intervalTitle(candidate),
                action: #selector(selectInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: candidate)
            item.state = abs(candidate - interval) < 0.01 ? .on : .off
            intervalMenu.addItem(item)
            intervalItems.append(item)
        }
        intervalMenuItem.submenu = intervalMenu
        intervalMenuItem.title = "刷新频率：\(Self.intervalTitle(interval))"
        menu.addItem(intervalMenuItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
        statusItem.isVisible = true
        statusItem.length = NSStatusItem.variableLength
        present(barTitle(cpu: nil, memory: nil, temperature: nil))

        sampler.onUpdate = { [weak self] metrics in
            self?.apply(metrics)
        }
        sampler.start()
    }

    static func savedInterval() -> TimeInterval {
        let stored = UserDefaults.standard.double(forKey: defaultsKey)
        return intervals.first { abs($0 - stored) < 0.01 } ?? 1
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let interval = (sender.representedObject as? NSNumber)?.doubleValue,
              let matched = Self.intervals.first(where: { abs($0 - interval) < 0.01 })
        else { return }

        UserDefaults.standard.set(matched, forKey: Self.defaultsKey)
        intervalMenuItem.title = "刷新频率：\(Self.intervalTitle(matched))"
        for item in intervalItems {
            let value = (item.representedObject as? NSNumber)?.doubleValue ?? 0
            item.state = abs(value - matched) < 0.01 ? .on : .off
        }
        sampler.setInterval(matched)
    }

    private static func intervalTitle(_ interval: TimeInterval) -> String {
        if interval < 1 {
            return String(format: "%.1f 秒", interval)
        }
        return "\(Int(interval)) 秒"
    }

    private func apply(_ metrics: SystemMetrics) {
        latest = metrics
        let signature = Self.signature(for: metrics)
        if signature != appliedSignature {
            appliedSignature = signature
            present(barTitle(
                cpu: metrics.cpuPercent,
                memory: metrics.memory?.percent,
                temperature: metrics.cpuTemperatureC
            ))
        }
        if menuOpen {
            updateMenu(metrics)
        }
    }

    private func updateMenu(_ metrics: SystemMetrics) {
        setTitle(cpuItem, "CPU：\(Self.percentText(metrics.cpuPercent, decimals: 1))")
        if let memory = metrics.memory {
            let used = Self.gigabytes(memory.usedBytes)
            let total = Self.gigabytes(memory.totalBytes)
            setTitle(
                memoryItem,
                "内存：\(used) / \(total) GB（\(Self.percentText(memory.percent, decimals: 0))）"
            )
        } else {
            setTitle(memoryItem, "内存：--")
        }
        if let temperature = metrics.cpuTemperatureC {
            setTitle(temperatureItem, String(format: "温度：%.1f°C", temperature))
        } else {
            setTitle(temperatureItem, "温度：--")
        }
    }

    private func setTitle(_ item: NSMenuItem, _ title: String) {
        if item.title != title {
            item.title = title
        }
    }

    private static func signature(for metrics: SystemMetrics) -> String {
        let cpu = metrics.cpuPercent.map { String(Int($0.rounded())) } ?? "-"
        let memory = metrics.memory.map { String(Int($0.percent.rounded())) } ?? "-"
        let temperature = metrics.cpuTemperatureC.map { String(Int($0.rounded())) } ?? "-"
        let color: Int
        if let celsius = metrics.cpuTemperatureC {
            color = celsius > 80 ? 2 : (celsius >= 60 ? 1 : 0)
        } else {
            color = 0
        }
        return "\(cpu)|\(memory)|\(temperature)|\(color)"
    }

    /// 菜单栏文字太宽时，系统会把状态项塞进刘海，看起来像右上角没有图标。
    /// 文字缩短后，如果仍落在刘海里，就挪到刘海右侧的可见区域。
    private func present(_ title: NSAttributedString) {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.font = font
        button.title = title.string
        statusItem.length = NSStatusItem.variableLength
        statusItem.isVisible = true
        button.attributedTitle = title
        moveOutOfNotch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.moveOutOfNotch()
        }
    }

    private func moveOutOfNotch() {
        guard let window = statusItem.button?.window,
              let right = window.screen?.auxiliaryTopRightArea
        else { return }
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return }
        guard frame.minX < right.minX else { return }
        let width = min(frame.width, right.width)
        let shifted = NSRect(
            x: right.minX + 4,
            y: frame.origin.y,
            width: width,
            height: frame.height
        )
        window.setFrame(shifted, display: true)
    }

    private func barTitle(cpu: Double?, memory: Double?, temperature: Double?) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let summary = "\(Self.percentText(cpu, decimals: 0)) \(Self.percentText(memory, decimals: 0)) "
        text.append(NSAttributedString(string: summary, attributes: base))

        var temperatureAttributes = base
        if let temperature {
            temperatureAttributes[.foregroundColor] = Self.temperatureColor(temperature)
        }
        let temperatureText = temperature.map { "\(Int($0.rounded()))°" } ?? "--"
        text.append(NSAttributedString(string: temperatureText, attributes: temperatureAttributes))
        return text
    }

    private static func temperatureColor(_ celsius: Double) -> NSColor {
        if celsius > 80 { return .systemRed }
        if celsius >= 60 { return .systemOrange }
        return .labelColor
    }

    private static func percentText(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "--" }
        if decimals == 0 {
            return "\(Int(value.rounded()))%"
        }
        return String(format: "%.\(decimals)f%%", value)
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        if let latest {
            updateMenu(latest)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }
}
