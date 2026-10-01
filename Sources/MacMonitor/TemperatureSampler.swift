import Darwin
import Foundation

struct ThermalSensor {
    var name: String
    var celsius: Double
}

/// CPU 温度。macOS 没有公开接口，通过 IOKit 私有 HID 传感器读取。
/// 客户端和 CPU 传感器列表只建立一次，之后每次采样只读数值。
final class TemperatureSampler {
    private let session = HIDSession()

    func sample() -> Double? {
        session.cpuTemperature()
    }

    func readSensors() -> [ThermalSensor] {
        session.allSensors()
    }
}

private final class HIDSession {
    private var client: UnsafeMutableRawPointer?
    private var services: Unmanaged<CFArray>?
    private var cpuServices: [UnsafeMutableRawPointer] = []
    private var preferred: UnsafeMutableRawPointer?
    private var opened = false
    private var nextOpenAttempt = Date.distantPast
    private var nextFullScan = Date.distantPast

    func cpuTemperature() -> Double? {
        autoreleasepool {
            if !opened {
                guard Date() >= nextOpenAttempt else { return nil }
                if !open() {
                    nextOpenAttempt = Date().addingTimeInterval(30)
                    return nil
                }
            }
            if Date() >= nextFullScan || preferred == nil {
                return fullScan()
            }
            if let preferred, let celsius = temperature(of: preferred), Self.isPlausible(celsius) {
                return celsius
            }
            return fullScan()
        }
    }

    /// 平时只读当前最热的那颗传感器。每隔几秒扫一遍全部 CPU 传感器，
    /// 确认最热点没有换到另一颗。
    private func fullScan() -> Double? {
        let reading = hottest()
        if reading.readAny || cpuServices.isEmpty {
            nextFullScan = Date().addingTimeInterval(5)
            return reading.value
        }
        close()
        guard open() else {
            nextOpenAttempt = Date().addingTimeInterval(30)
            return nil
        }
        let retry = hottest()
        if retry.readAny {
            nextFullScan = Date().addingTimeInterval(5)
        } else {
            close()
            nextOpenAttempt = Date().addingTimeInterval(30)
        }
        return retry.value
    }

    func allSensors() -> [ThermalSensor] {
        autoreleasepool {
            if !opened, !open() { return [] }
            return sensors(matching: nil)
        }
    }

    private func hottest() -> (value: Double?, readAny: Bool) {
        guard !cpuServices.isEmpty else { return (nil, false) }
        var maxValue: Double?
        var maxService: UnsafeMutableRawPointer?
        var readAny = false
        for service in cpuServices {
            guard let celsius = temperature(of: service) else { continue }
            readAny = true
            guard Self.isPlausible(celsius) else { continue }
            if celsius > maxValue ?? -.infinity {
                maxValue = celsius
                maxService = service
            }
        }
        if let maxService {
            preferred = maxService
        }
        return (maxValue, readAny)
    }

    private func open() -> Bool {
        close()
        guard
            let create = HIDAPI.create,
            let setMatching = HIDAPI.setMatching,
            let copyServices = HIDAPI.copyServices,
            let client = create(kCFAllocatorDefault)
        else { return false }

        setMatching(client, HIDAPI.matching)
        guard let services = copyServices(client) else {
            Unmanaged<CFTypeRef>.fromOpaque(client).release()
            return false
        }

        self.client = client
        self.services = services
        opened = true

        let array = services.takeUnretainedValue()
        let count = CFArrayGetCount(array)
        cpuServices.reserveCapacity(4)
        for index in 0..<count {
            guard let rawService = CFArrayGetValueAtIndex(array, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: rawService)
            guard let name = productName(of: service), Self.isCPUSensor(name) else { continue }
            cpuServices.append(service)
        }
        return true
    }

    private func close() {
        preferred = nil
        cpuServices.removeAll(keepingCapacity: true)
        services?.release()
        services = nil
        if let client {
            Unmanaged<CFTypeRef>.fromOpaque(client).release()
            self.client = nil
        }
        opened = false
    }

    private func sensors(matching predicate: ((String) -> Bool)?) -> [ThermalSensor] {
        guard let services else { return [] }
        let array = services.takeUnretainedValue()
        var found: [ThermalSensor] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let rawService = CFArrayGetValueAtIndex(array, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: rawService)
            guard let name = productName(of: service) else { continue }
            if let predicate, !predicate(name) { continue }
            guard let celsius = temperature(of: service) else { continue }
            found.append(ThermalSensor(name: name, celsius: celsius))
        }
        return found
    }

    private func productName(of service: UnsafeMutableRawPointer) -> String? {
        guard
            let copyProperty = HIDAPI.copyProperty,
            let property = copyProperty(service, "Product" as CFString)?.takeRetainedValue(),
            CFGetTypeID(property) == CFStringGetTypeID()
        else { return nil }
        return property as! CFString as String
    }

    private func temperature(of service: UnsafeMutableRawPointer) -> Double? {
        guard
            let copyEvent = HIDAPI.copyEvent,
            let getFloatValue = HIDAPI.getFloatValue,
            let event = copyEvent(service, HIDAPI.temperatureType, 0, 0)
        else { return nil }
        let celsius = getFloatValue(event, HIDAPI.temperatureField)
        Unmanaged<CFTypeRef>.fromOpaque(event).release()
        return celsius
    }

    private static func isCPUSensor(_ name: String) -> Bool {
        name.contains("PMU tdie")
            || name.contains("pACC MTR")
            || name.contains("eACC MTR")
    }

    private static func isPlausible(_ celsius: Double) -> Bool {
        celsius >= 1 && celsius <= 125
    }

    deinit {
        close()
    }
}

private enum HIDAPI {
    static let handle = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        RTLD_LAZY
    )

    typealias CreateFunc = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    typealias SetMatchingFunc = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
    typealias CopyServicesFunc = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    typealias CopyPropertyFunc = @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<CFTypeRef>?
    typealias CopyEventFunc = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    typealias GetFloatFunc = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    static let create: CreateFunc? = load("IOHIDEventSystemClientCreate")
    static let setMatching: SetMatchingFunc? = load("IOHIDEventSystemClientSetMatching")
    static let copyServices: CopyServicesFunc? = load("IOHIDEventSystemClientCopyServices")
    static let copyProperty: CopyPropertyFunc? = load("IOHIDServiceClientCopyProperty")
    static let copyEvent: CopyEventFunc? = load("IOHIDServiceClientCopyEvent")
    static let getFloatValue: GetFloatFunc? = load("IOHIDEventGetFloatValue")

    static let temperatureType: Int64 = 15
    static let temperatureField = Int32(temperatureType << 16)

    static let matching: CFDictionary = {
        var page: Int32 = 0xFF00
        var usage: Int32 = 5
        let pageNumber = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &page)
        let usageNumber = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &usage)
        return [
            "PrimaryUsagePage" as CFString: pageNumber as Any,
            "PrimaryUsage" as CFString: usageNumber as Any,
        ] as CFDictionary
    }()

    private static func load<T>(_ name: String) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
