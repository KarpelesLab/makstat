import Foundation
import Combine
import WidgetKit

/// Owns the sampling loop. Samplers run on a background queue; published state is updated on the main actor.
@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published var popoverVisible = false { didSet { if popoverVisible { kick() } } }

    let store = RuleStore()
    let engine = RuleEngine()
    static let historyLength = 90

    private let system = SystemSampler()
    private let processes = ProcessSampler()
    private let queue = DispatchQueue(label: "makstat.sampler", qos: .utility)
    private var loop: Task<Void, Never>?
    private var lastWidgetPush = Date.distantPast
    private var wakeup: CheckedContinuation<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // Two quick samples so rates are meaningful right away.
            await self?.sampleOnce()
            try? await Task.sleep(for: .milliseconds(700))
            while !Task.isCancelled {
                await self?.sampleOnce()
                let interval = self?.currentInterval ?? 3
                await self?.sleep(interval)
            }
        }
    }

    /// Sample immediately instead of waiting for the next tick.
    func kick() {
        wakeup?.resume()
        wakeup = nil
    }

    private var currentInterval: TimeInterval {
        if popoverVisible { return 1.5 }
        return max(1, UserDefaults.standard.double(forKey: PrefKey.sampleInterval))
    }

    private func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wakeup = c
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.wakeup != nil else { return }
                self.wakeup = nil
                c.resume()
            }
        }
    }

    private func sampleOnce() async {
        let system = self.system, processes = self.processes, queue = self.queue
        let snap: Snapshot = await withCheckedContinuation { c in
            queue.async {
                var s = Snapshot()
                let sys = system.sample()
                s.cpu = sys.cpu; s.memory = sys.memory; s.disk = sys.disk; s.network = sys.network
                let p = processes.sample()
                s.groups = p.groups; s.processCount = p.processCount; s.hiddenProcessCount = p.hidden
                s.uptime = ProcessInfo.processInfo.systemUptime
                s.timestamp = Date()
                c.resume(returning: s)
            }
        }
        snapshot = snap
        cpuHistory.append(snap.cpu.usage)
        memoryHistory.append(snap.memory.usedFraction * 100)
        if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }
        if memoryHistory.count > Self.historyLength { memoryHistory.removeFirst(memoryHistory.count - Self.historyLength) }
        engine.evaluate(snap, store: store)
        pushToWidget(snap)
    }

    private func pushToWidget(_ snap: Snapshot) {
        // The first sample has no rates yet (CPU, disk and network all read zero).
        guard cpuHistory.count >= 2 else { return }
        let interval = max(30, UserDefaults.standard.double(forKey: PrefKey.widgetRefresh))
        guard Date().timeIntervalSince(lastWidgetPush) >= interval else { return }
        lastWidgetPush = Date()
        let trimmed = snap.trimmed()
        queue.async {
            SharedStore.write(trimmed)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func refreshWidgetNow() {
        lastWidgetPush = .distantPast
        pushToWidget(snapshot)
    }

    // MARK: Manual process control

    func signal(_ p: ProcessSample, _ sig: Int32) {
        let name = sig == SIGKILL ? "SIGKILL" : "SIGTERM"
        if kill(p.pid, sig) == 0 {
            store.log(.action, "Manual: sent \(name) to \(p.name) (pid \(p.pid))")
        } else {
            store.log(.error, "Manual: \(name) \(p.name) (pid \(p.pid)) failed: \(String(cString: strerror(errno)))")
        }
        Task { try? await Task.sleep(for: .milliseconds(300)); kick() }
    }
}
