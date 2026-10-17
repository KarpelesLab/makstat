import Foundation

/// App group identifier shared between the app and the widget.
/// macOS requires the team identifier prefix for app groups.
let makstatAppGroup = "BTXR2WSDG9.com.magicaltux.makstat"

struct CPUStats: Codable, Equatable {
    var usage: Double = 0          // 0...100, all cores combined
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []     // 0...100 each
    var loadAverage: [Double] = [0, 0, 0]
    var coreCount: Int = 0
}

enum MemoryPressure: Int, Codable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

struct MemoryStats: Codable, Equatable {
    var total: UInt64 = 0
    var used: UInt64 = 0           // app + wired + compressed (Activity Monitor "Memory Used")
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0         // file-backed, reclaimable
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: MemoryPressure = .normal

    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct VolumeStats: Codable, Equatable, Identifiable {
    var id: String { mountPoint }
    var name: String
    var mountPoint: String
    var total: UInt64
    var free: UInt64

    var used: UInt64 { total > free ? total - free : 0 }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct DiskStats: Codable, Equatable {
    var volumes: [VolumeStats] = []
    var readRate: Double = 0       // bytes per second, all block devices
    var writeRate: Double = 0
}

struct NetworkStats: Codable, Equatable {
    var inRate: Double = 0         // bytes per second
    var outRate: Double = 0
}

struct ProcessSample: Codable, Equatable, Identifiable {
    var id: Int32 { pid }
    var pid: Int32
    var ppid: Int32
    var name: String
    var path: String?
    var uid: UInt32
    var startTime: TimeInterval    // unix time; with pid identifies a process instance
    var cpu: Double                // percent of one core
    var memory: UInt64             // physical footprint, bytes
    var diskRead: Double           // bytes per second
    var diskWrite: Double
    var threads: Int
    var detailed: Bool             // false when the process belongs to another user
}

struct ProcessGroup: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var cpu: Double
    var memory: UInt64
    var diskRead: Double
    var diskWrite: Double
    var processes: [ProcessSample]
    var count: Int { processes.count }
    var detailed: Bool { processes.contains { $0.detailed } }
}

struct Snapshot: Codable, Equatable {
    var timestamp = Date()
    var cpu = CPUStats()
    var memory = MemoryStats()
    var disk = DiskStats()
    var network = NetworkStats()
    var groups: [ProcessGroup] = []
    var processCount = 0
    var hiddenProcessCount = 0     // processes we cannot inspect (other users / root)
    var uptime: TimeInterval = 0

    func topGroups(by sort: ProcessSort, limit: Int) -> [ProcessGroup] {
        Array(groups.sorted(by: sort.areInIncreasingOrder).prefix(limit))
    }

    /// Reduced copy for the widget: keeps only the heaviest groups and their top processes.
    func trimmed(groupLimit: Int = 12, processLimit: Int = 5) -> Snapshot {
        var copy = self
        var keep: [String: ProcessGroup] = [:]
        for sort in ProcessSort.allCases {
            for g in topGroups(by: sort, limit: groupLimit) { keep[g.name] = g }
        }
        copy.groups = keep.values.map { g in
            var g = g
            g.processes = Array(g.processes.sorted { $0.memory > $1.memory }.prefix(processLimit))
            return g
        }.sorted(by: ProcessSort.cpu.areInIncreasingOrder)
        return copy
    }
}

enum ProcessSort: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, disk
    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk I/O"
        }
    }

    var areInIncreasingOrder: (ProcessGroup, ProcessGroup) -> Bool {
        switch self {
        case .cpu: return { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }
        case .memory: return { $0.memory != $1.memory ? $0.memory > $1.memory : $0.cpu > $1.cpu }
        case .disk: return { ($0.diskRead + $0.diskWrite) > ($1.diskRead + $1.diskWrite) }
        }
    }

    var processOrder: (ProcessSample, ProcessSample) -> Bool {
        switch self {
        case .cpu: return { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }
        case .memory: return { $0.memory > $1.memory }
        case .disk: return { ($0.diskRead + $0.diskWrite) > ($1.diskRead + $1.diskWrite) }
        }
    }
}
