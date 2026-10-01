import AppKit

final class StatusBarController: NSObject {
    static let intervals: [TimeInterval] = [0.5, 1, 2, 5, 10]
    private static let defaultsKey = "sampleInterval"
    private static let sortDefaultsKey = "appSort"
    private static let appRowCount = 10

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let cpuItem = NSMenuItem(title: "CPU：--", action: nil, keyEquivalent: "")
    private let memoryItem = NSMenuItem(title: "内存：--", action: nil, keyEquivalent: "")
    private let temperatureItem = NSMenuItem(title: "温度：--", action: nil, keyEquivalent: "")
    private let intervalMenuItem = NSMenuItem(title: "刷新频率", action: nil, keyEquivalent: "")
    private var intervalItems: [NSMenuItem] = []
    private var appItems: [NSMenuItem] = []
    private let sortByCPUItem = NSMenuItem(title: "按 CPU", action: #selector(selectAppSort(_:)), keyEquivalent: "")
    private let sortByMemoryItem = NSMenuItem(title: "按内存", action: #selector(selectAppSort(_:)), keyEquivalent: "")
    private var sortByMemory = false
    private let sampler: MetricsSampler
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private var menuOpen = false
    private var latest: SystemMetrics?
    private var appliedSignature: String?
    private var compact = false
    private var displayedTitle: NSAttributedString?
    private var modeChangedAt = Date.distantPast
    /// 读数可以压住旁边图标的宽度。小于这点仍显示文字，再窄才收成图标。
    private static let overlapAllowance: CGFloat = 48
    private lazy var compactImage: NSImage = {
        let base = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "性能")
            ?? NSImage(systemSymbolName: "speedometer", accessibilityDescription: "性能")
            ?? NSImage()
        let configured = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)) ?? base
        configured.isTemplate = true
        return configured
    }()

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

        let appHeader = NSMenuItem(title: "应用占用", action: nil, keyEquivalent: "")
        appHeader.isEnabled = false
        menu.addItem(appHeader)
        for _ in 0..<Self.appRowCount {
            let item = NSMenuItem(title: "正在统计…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.isHidden = true
            menu.addItem(item)
            appItems.append(item)
        }
        sortByMemory = UserDefaults.standard.string(forKey: Self.sortDefaultsKey) == "memory"
        let sortMenu = NSMenu()
        for item in [sortByCPUItem, sortByMemoryItem] {
            item.target = self
            sortMenu.addItem(item)
        }
        updateSortChecks()
        let sortItem = NSMenuItem(title: "排序", action: nil, keyEquivalent: "")
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)
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

    @objc private func selectAppSort(_ sender: NSMenuItem) {
        sortByMemory = sender === sortByMemoryItem
        UserDefaults.standard.set(sortByMemory ? "memory" : "cpu", forKey: Self.sortDefaultsKey)
        updateSortChecks()
        if let latest {
            updateAppItems(latest.apps)
        }
    }

    private func updateSortChecks() {
        sortByCPUItem.state = sortByMemory ? .off : .on
        sortByMemoryItem.state = sortByMemory ? .on : .off
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
        } else {
            refreshCompactMode()
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
        updateAppItems(metrics.apps)
    }

    private func updateAppItems(_ apps: [AppUsage]) {
        let ranked = apps.sorted { lhs, rhs in
            if sortByMemory {
                return lhs.memoryBytes == rhs.memoryBytes
                    ? lhs.cpuPercent > rhs.cpuPercent
                    : lhs.memoryBytes > rhs.memoryBytes
            }
            return lhs.cpuPercent == rhs.cpuPercent
                ? lhs.memoryBytes > rhs.memoryBytes
                : lhs.cpuPercent > rhs.cpuPercent
        }
        let top = Array(ranked.prefix(Self.appRowCount))
        for (index, item) in appItems.enumerated() {
            if index < top.count {
                setTitle(item, Self.appTitle(top[index]))
                item.isHidden = false
            } else if index == 0, top.isEmpty {
                setTitle(item, "正在统计…")
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }
    }

    private static func appTitle(_ app: AppUsage) -> String {
        let name = app.name.count > 22 ? String(app.name.prefix(21)) + "…" : app.name
        return "\(name)    \(percentText(app.cpuPercent, decimals: 1))    \(memoryText(app.memoryBytes))"
    }

    private static func memoryText(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1024 {
            return String(format: "%.0f MB", megabytes)
        }
        return String(format: "%.1f GB", megabytes / 1024)
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

    /// 菜单栏右侧放不下整行读数时，收成一个小图标。点开菜单仍能看到全部内容。
    private func present(_ title: NSAttributedString) {
        displayedTitle = title
        guard let button = statusItem.button else { return }
        statusItem.isVisible = true
        button.toolTip = title.string
        if compact {
            showCompactIcon(on: button, temperature: latest?.cpuTemperatureC)
        } else {
            showFullTitle(title, on: button)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshCompactMode()
        }
    }

    private func showFullTitle(_ title: NSAttributedString, on button: NSStatusBarButton) {
        button.image = nil
        button.imagePosition = .noImage
        button.contentTintColor = nil
        button.font = font
        button.title = title.string
        if statusItem.length != NSStatusItem.variableLength {
            statusItem.length = NSStatusItem.variableLength
        }
        button.attributedTitle = title
    }

    private func showCompactIcon(on button: NSStatusBarButton, temperature: Double?) {
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
        button.image = compactImage
        button.imagePosition = .imageOnly
        button.contentTintColor = Self.temperatureTint(temperature)
        if statusItem.length != NSStatusItem.squareLength {
            statusItem.length = NSStatusItem.squareLength
        }
    }

    private func refreshCompactMode() {
        guard let title = displayedTitle,
              let window = statusItem.button?.window,
              let right = window.screen?.auxiliaryTopRightArea
        else { return }
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return }

        let needed = ceil(title.size().width) + 22
        let layout = menuBarLayout(in: right)
        let neighborMinX = layout.neighborMinX
        // 用其他图标占用的总宽度，而不是它们被挤到的位置。否则展开后空隙变小，又会立刻收起。
        let room = max(0, right.width - layout.occupied) + Self.overlapAllowance
        // 已经展开时多留一截，避免空隙在临界值附近时文字和图标来回切换。
        let wantsCompact = compact ? room < needed : room + 32 < needed
        if wantsCompact != compact, Date().timeIntervalSince(modeChangedAt) > 2 {
            modeChangedAt = Date()
            compact = wantsCompact
            present(title)
            return
        }

        if compact {
            placeIconInGap(frame: frame, safe: right, neighborMinX: neighborMinX)
        } else if frame.minX < right.minX - 1 {
            nudgeOutOfNotch(frame: frame, safe: right)
        }
    }

    /// 只有整段落进刘海、完全看不见时才挪一次。不要每次刷新都改位置。
    private func nudgeOutOfNotch(frame: NSRect, safe: NSRect) {
        guard let window = statusItem.button?.window else { return }
        let x = safe.minX + 2
        guard abs(x - frame.minX) >= 1.5 else { return }
        window.setFrame(
            NSRect(x: x, y: frame.origin.y, width: frame.width, height: frame.height),
            display: true
        )
    }

    /// 小图标仍然压住旁边的图标或刘海时，把它放进刘海右侧的空隙里。
    private func placeIconInGap(frame: NSRect, safe: NSRect, neighborMinX: CGFloat?) {
        guard let window = statusItem.button?.window else { return }
        let width = frame.width
        var x = frame.minX
        if x < safe.minX - 1 {
            x = safe.minX + 2
        }
        if let neighborMinX, x + width > neighborMinX - 2 {
            x = neighborMinX - width - 2
        }
        if x < safe.minX {
            x = safe.minX + 2
        }
        guard abs(x - frame.minX) >= 1.5 else { return }
        window.setFrame(
            NSRect(x: x, y: frame.origin.y, width: width, height: frame.height),
            display: true
        )
    }

    /// 刘海右侧其他菜单栏窗口的左边缘，以及它们实际占掉的宽度。
    private func menuBarLayout(in right: NSRect) -> (neighborMinX: CGFloat?, occupied: CGFloat) {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return (nil, 0)
        }
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let ourWindow = statusItem.button?.window?.windowNumber ?? 0
        var spans: [(CGFloat, CGFloat)] = []
        var neighbor: CGFloat?
        for entry in info {
            let number = entry[kCGWindowNumber as String] as? Int ?? -1
            if number == ourWindow { continue }
            if Self.cgFloat(entry[kCGWindowOwnerPID as String]) == CGFloat(ourPID) { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = Self.cgFloat(bounds["X"])
            let y = Self.cgFloat(bounds["Y"])
            let width = Self.cgFloat(bounds["Width"])
            let height = Self.cgFloat(bounds["Height"])
            guard y >= 0, y < 48, height > 0, height < 80, width > 8, width < right.width * 0.8 else { continue }
            let minX = max(x, right.minX)
            let maxX = min(x + width, right.maxX)
            guard maxX - minX > 4 else { continue }
            spans.append((minX, maxX))
            if x >= right.minX - 2, x < right.maxX {
                neighbor = min(neighbor ?? right.maxX, x)
            }
        }
        spans.sort { $0.0 < $1.0 }
        var occupied: CGFloat = 0
        var end: CGFloat = right.minX
        for span in spans {
            let start = max(span.0, end)
            if span.1 > start {
                occupied += span.1 - start
                end = span.1
            }
        }
        return (neighbor, occupied)
    }

    private static func cgFloat(_ value: Any?) -> CGFloat {
        if let number = value as? CGFloat { return number }
        if let number = value as? Double { return CGFloat(number) }
        if let number = value as? Int { return CGFloat(number) }
        return 0
    }

    private static func temperatureTint(_ celsius: Double?) -> NSColor? {
        guard let celsius else { return nil }
        if celsius > 80 { return .systemRed }
        if celsius >= 60 { return .systemOrange }
        return nil
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
