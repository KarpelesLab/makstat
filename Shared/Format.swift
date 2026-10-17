import Foundation

enum Format {
    /// Memory sizes: binary units, labelled the way macOS does (GB meaning 2^30).
    static func bytes(_ value: UInt64, decimals: Int = 1) -> String {
        bytes(Double(value), decimals: decimals)
    }

    static func bytes(_ value: Double, decimals: Int = 1) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = value
        var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(Int(v)) B" }
        let d = v >= 100 ? 0 : decimals
        return String(format: "%.\(d)f %@", v, units[i])
    }

    /// Disk capacities: decimal units like Finder.
    static func diskBytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        let d = v >= 100 || i == 0 ? 0 : 1
        return String(format: "%.\(d)f %@", v, units[i])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1024 { return "\(Int(bytesPerSecond)) B/s" }
        return bytes(bytesPerSecond, decimals: 1) + "/s"
    }

    static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", value)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
