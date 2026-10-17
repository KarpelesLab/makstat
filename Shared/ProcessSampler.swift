import Foundation
import Darwin

/// Enumerates processes and groups them by executable name.
/// CPU and disk rates are computed against the previous sample.
final class ProcessSampler {
    private struct Previous {
        var cpuTime: UInt64      // nanoseconds
        var diskRead: UInt64
        var diskWrite: UInt64
        var at: TimeInterval
    }
    private struct Key: Hashable {
        let pid: pid_t
        let start: TimeInterval
    }

    private var previous: [Key: Previous] = [:]
    private var nameCache: [Key: (name: String, path: String?)] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()
    private let ownUID = getuid()

    func sample() -> (groups: [ProcessGroup], processCount: Int, hidden: Int) {
        let procs = Self.listProcesses()
        let now = Date().timeIntervalSince1970
        var samples: [ProcessSample] = []
        samples.reserveCapacity(procs.count)
        var seen = Set<Key>()
        var hidden = 0

        for kp in procs {
            let pid = kp.kp_proc.p_pid
            if pid == 0 { continue }
            let start = TimeInterval(kp.kp_proc.p_starttime.tv_sec) + TimeInterval(kp.kp_proc.p_starttime.tv_usec) / 1e6
            let key = Key(pid: pid, start: start)
            seen.insert(key)
            let uid = kp.kp_eproc.e_ucred.cr_uid
            let comm = withUnsafePointer(to: kp.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }

            let (name, path) = resolveName(key: key, comm: comm)
            var s = ProcessSample(pid: pid, ppid: kp.kp_eproc.e_ppid, name: name, path: path, uid: uid,
                                  startTime: start, cpu: 0, memory: 0, diskRead: 0, diskWrite: 0,
                                  threads: 0, detailed: false)

            var ri = rusage_info_v4()
            // The header types the buffer as `rusage_info_t *` (a void **) but the kernel
            // writes the struct itself into it, so cast rather than passing a pointer slot.
            let ok = withUnsafeMutablePointer(to: &ri) { ptr -> Bool in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: rusage_info_t?.self)
                return proc_pid_rusage(pid, RUSAGE_INFO_V4, raw) == 0
            }
            if ok {
                s.detailed = true
                s.memory = ri.ri_phys_footprint
                let cpuNS = (ri.ri_user_time &+ ri.ri_system_time) &* timebase.numer / timebase.denom
                if let p = previous[key] {
                    let dt = now - p.at
                    if dt > 0 {
                        s.cpu = Double(cpuNS &- p.cpuTime) / (dt * 1e9) * 100
                        s.diskRead = Double(ri.ri_diskio_bytesread &- p.diskRead) / dt
                        s.diskWrite = Double(ri.ri_diskio_byteswritten &- p.diskWrite) / dt
                    }
                }
                previous[key] = Previous(cpuTime: cpuNS, diskRead: ri.ri_diskio_bytesread,
                                         diskWrite: ri.ri_diskio_byteswritten, at: now)
                var ti = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.size)
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size {
                    s.threads = Int(ti.pti_threadnum)
                }
            } else {
                hidden += 1
            }
            samples.append(s)
        }

        // Drop state for processes that are gone.
        previous = previous.filter { seen.contains($0.key) }
        nameCache = nameCache.filter { seen.contains($0.key) }

        var byName: [String: [ProcessSample]] = [:]
        for s in samples { byName[s.name, default: []].append(s) }
        let groups = byName.map { name, procs -> ProcessGroup in
            ProcessGroup(name: name,
                         cpu: procs.reduce(0) { $0 + $1.cpu },
                         memory: procs.reduce(0) { $0 + $1.memory },
                         diskRead: procs.reduce(0) { $0 + $1.diskRead },
                         diskWrite: procs.reduce(0) { $0 + $1.diskWrite },
                         processes: procs.sorted { $0.memory > $1.memory })
        }
        return (groups, samples.count, hidden)
    }

    private func resolveName(key: Key, comm: String) -> (String, String?) {
        if let cached = nameCache[key] { return cached }
        var result: (String, String?) = (comm, nil)
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(key.pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            let last = (path as NSString).lastPathComponent
            result = (last.isEmpty ? comm : last, path)
        } else {
            var nbuf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
            if proc_name(key.pid, &nbuf, UInt32(nbuf.count)) > 0 {
                let n = String(cString: nbuf)
                if !n.isEmpty { result = (n, nil) }
            }
        }
        nameCache[key] = result
        return result
    }

    static func listProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buffer.count * stride
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return Array(buffer.prefix(size / stride))
    }

    /// Command line of a process (argv), or nil when unavailable.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        // Skip executable path.
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        var current: [UInt8] = []
        while i < size, args.count < argc {
            if buffer[i] == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(buffer[i])
            }
            i += 1
        }
        return args
    }

    /// Whether a given process instance is still alive.
    static func isAlive(pid: pid_t, startTime: TimeInterval) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0, kp.kp_proc.p_pid == pid else { return false }
        let start = TimeInterval(kp.kp_proc.p_starttime.tv_sec) + TimeInterval(kp.kp_proc.p_starttime.tv_usec) / 1e6
        return abs(start - startTime) < 1
    }
}
