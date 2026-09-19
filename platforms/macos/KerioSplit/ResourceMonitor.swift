import Foundation
import Darwin

/// Samples this process CPU/RAM and system memory off the main thread.
@MainActor
final class ResourceMonitor: ObservableObject {
    @Published var cpuPercent: Double = 0
    @Published var appMemoryMB: Double = 0
    @Published var systemUsedGB: Double = 0
    @Published var systemTotalGB: Double = 0
    @Published var systemPercent: Double = 0

    var cpuText: String { String(format: "%.0f%%", cpuPercent) }
    var appMemoryText: String {
        if appMemoryMB >= 1024 {
            return String(format: "%.1f GB", appMemoryMB / 1024)
        }
        return String(format: "%.0f MB", appMemoryMB)
    }
    var systemMemoryText: String {
        String(format: "%.1f / %.0f GB", systemUsedGB, systemTotalGB)
    }

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snap = Self.capture()
            DispatchQueue.main.async {
                guard let self else { return }
                self.cpuPercent = snap.cpu
                self.appMemoryMB = snap.appMB
                self.systemUsedGB = snap.sysUsedGB
                self.systemTotalGB = snap.sysTotalGB
                self.systemPercent = snap.sysPercent
            }
        }
    }

    private nonisolated static func capture() -> (cpu: Double, appMB: Double, sysUsedGB: Double, sysTotalGB: Double, sysPercent: Double) {
        let appMB = Double(residentBytes()) / 1_048_576
        let cpu = processCPUPercent()
        let (used, total) = systemMemoryBytes()
        let usedGB = Double(used) / 1_073_741_824
        let totalGB = Double(total) / 1_073_741_824
        let pct = total > 0 ? (Double(used) / Double(total)) * 100 : 0
        return (cpu, appMB, usedGB, totalGB, pct)
    }

    private nonisolated static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private nonisolated static func systemMemoryBytes() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let used = min(usedPages * page, total)
        return (used, total)
    }

    private nonisolated static func processCPUPercent() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS,
              let threads else { return 0 }

        defer {
            let size = vm_size_t(MemoryLayout<thread_t>.stride * Int(count))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), size)
        }

        var totalUsage: Double = 0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { intPtr in
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), intPtr, &infoCount)
                }
            }
            guard result == KERN_SUCCESS else { continue }
            if info.flags & TH_FLAGS_IDLE != 0 { continue }
            totalUsage += Double(info.cpu_usage)
        }
        let scale = Double(TH_USAGE_SCALE)
        guard scale > 0 else { return 0 }
        return min(100, (totalUsage / scale) * 100)
    }
}
