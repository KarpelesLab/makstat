import Foundation
import IOKit

/// Samples whole-system counters. Rates (CPU %, disk and network throughput) are
/// derived from the delta against the previous call, so the first sample reports zero.
/// Not thread-safe; the app drives it from one serial queue.
final class SystemSampler: @unchecked Sendable {
    private var prevCPU: [[UInt32]]?          // per core: user, system, idle, nice ticks
    private var prevDisk: (read: UInt64, write: UInt64, at: Date)?
    private var prevNet: (inBytes: UInt64, outBytes: UInt64, at: Date)?
    private var netWrap: (inBase: UInt64, outBase: UInt64, lastIn: UInt32, lastOut: UInt32) = (0, 0, 0, 0)

    private let totalMemory: UInt64 = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return size
    }()

    func sample() -> (cpu: CPUStats, memory: MemoryStats, disk: DiskStats, network: NetworkStats) {
        (sampleCPU(), sampleMemory(), sampleDisk(), sampleNetwork())
    }

    // MARK: CPU

    func sampleCPU() -> CPUStats {
        var stats = CPUStats()
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return stats }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        current.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * states
            current.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }
        stats.coreCount = Int(cpuCount)
        if let prev = prevCPU, prev.count == current.count {
            var totalUser = 0.0, totalSys = 0.0, totalAll = 0.0
            for i in 0..<current.count {
                let user = Double(current[i][0] &- prev[i][0]) + Double(current[i][3] &- prev[i][3])
                let sys = Double(current[i][1] &- prev[i][1])
                let idle = Double(current[i][2] &- prev[i][2])
                let all = user + sys + idle
                stats.perCore.append(all > 0 ? (user + sys) / all * 100 : 0)
                totalUser += user; totalSys += sys; totalAll += all
            }
            if totalAll > 0 {
                stats.user = totalUser / totalAll * 100
                stats.system = totalSys / totalAll * 100
                stats.usage = stats.user + stats.system
            }
        } else {
            stats.perCore = Array(repeating: 0, count: current.count)
        }
        prevCPU = current

        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { stats.loadAverage = load }
        return stats
    }

    // MARK: Memory

    func sampleMemory() -> MemoryStats {
        var m = MemoryStats()
        m.total = totalMemory
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            m.wired = UInt64(vm.wire_count) * page
            m.compressed = UInt64(vm.compressor_page_count) * page
            m.cached = (UInt64(vm.external_page_count) + purgeable) * page
            m.free = UInt64(vm.free_count) * page
            m.used = m.app + m.wired + m.compressed
        }
        var swap = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &len, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used
            m.swapTotal = swap.xsu_total
        }
        var level: Int32 = 1
        var llen = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &llen, nil, 0) == 0 {
            m.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
        return m
    }

    // MARK: Disk

    func sampleDisk() -> DiskStats {
        var d = DiskStats()
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let free = v.volumeAvailableCapacityForImportantUsage ?? 0
            d.volumes.append(VolumeStats(name: v.volumeName ?? url.lastPathComponent,
                                         mountPoint: url.path, total: UInt64(total), free: UInt64(max(0, free))))
        }
        // Root first, then by mount point.
        d.volumes.sort { a, b in
            if a.mountPoint == "/" { return true }
            if b.mountPoint == "/" { return false }
            return a.mountPoint < b.mountPoint
        }

        if let io = Self.blockDeviceTotals() {
            let now = Date()
            if let p = prevDisk {
                let dt = now.timeIntervalSince(p.at)
                if dt > 0 {
                    d.readRate = Double(io.read &- p.read) / dt
                    d.writeRate = Double(io.write &- p.write) / dt
                }
            }
            prevDisk = (io.read, io.write, now)
        }
        return d
    }

    private static func blockDeviceTotals() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        var found = false
        while true {
            let drive = IOIteratorNext(iterator)
            if drive == 0 { break }
            defer { IOObjectRelease(drive) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(drive, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any] else { continue }
            found = true
            read &+= (stats["Bytes (Read)"] as? UInt64) ?? 0
            write &+= (stats["Bytes (Write)"] as? UInt64) ?? 0
        }
        return found ? (read, write) : nil
    }

    // MARK: Network

    func sampleNetwork() -> NetworkStats {
        var n = NetworkStats()
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return n }
        defer { freeifaddrs(addrs) }
        var inBytes: UInt32 = 0, outBytes: UInt32 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            let flags = Int32(ifa.pointee.ifa_flags)
            if flags & IFF_UP == 0 { continue }
            let ifd = data.assumingMemoryBound(to: if_data.self).pointee
            inBytes &+= ifd.ifi_ibytes
            outBytes &+= ifd.ifi_obytes
        }
        // Counters are 32-bit; keep a 64-bit running total that survives wraps.
        if inBytes < netWrap.lastIn { netWrap.inBase &+= UInt64(UInt32.max) &+ 1 }
        if outBytes < netWrap.lastOut { netWrap.outBase &+= UInt64(UInt32.max) &+ 1 }
        netWrap.lastIn = inBytes; netWrap.lastOut = outBytes
        let totalIn = netWrap.inBase &+ UInt64(inBytes)
        let totalOut = netWrap.outBase &+ UInt64(outBytes)
        let now = Date()
        if let p = prevNet {
            let dt = now.timeIntervalSince(p.at)
            if dt > 0 {
                n.inRate = max(0, Double(totalIn &- p.inBytes) / dt)
                n.outRate = max(0, Double(totalOut &- p.outBytes) / dt)
            }
        }
        prevNet = (totalIn, totalOut, now)
        return n
    }
}
