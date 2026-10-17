import Foundation
import Darwin

/// Evaluates rules against each snapshot and carries out their actions.
@MainActor
final class RuleEngine {
    private struct Key: Hashable {
        let rule: UUID
        let pid: pid_t
        let start: TimeInterval
    }
    private struct Tracking {
        var since: Date?         // when the condition started holding
        var lastFired: Date?
        var terminatedAt: Date?  // SIGTERM sent, waiting to escalate
    }

    private var tracking: [Key: Tracking] = [:]
    private let ownPID = getpid()
    static let escalationDelay: TimeInterval = 10
    static let renotifyInterval: TimeInterval = 120

    func evaluate(_ snapshot: Snapshot, store: RuleStore) {
        let rules = store.rules.filter { $0.enabled }
        let protected = Prefs.protectedNames
        let now = snapshot.timestamp
        var live = Set<Key>()
        guard !rules.isEmpty else { tracking.removeAll(); return }

        for group in snapshot.groups {
            for p in group.processes where p.detailed && p.pid > 1 && p.pid != ownPID {
                for rule in rules where rule.matches(p) {
                    let key = Key(rule: rule.id, pid: p.pid, start: p.startTime)
                    live.insert(key)
                    var t = tracking[key] ?? Tracking()
                    let value = rule.value(of: p)

                    // Pending SIGTERM escalation: the process is still here and still over.
                    if let termAt = t.terminatedAt {
                        if value >= rule.threshold, now.timeIntervalSince(termAt) >= Self.escalationDelay {
                            if kill(p.pid, SIGKILL) == 0 {
                                store.log(.action, "\(rule.label): \(p.name) (pid \(p.pid)) ignored SIGTERM, sent SIGKILL")
                            } else {
                                store.log(.error, "\(rule.label): SIGKILL \(p.name) (pid \(p.pid)) failed: \(String(cString: strerror(errno)))")
                            }
                            t.terminatedAt = nil
                        }
                        tracking[key] = t
                        continue
                    }

                    if value >= rule.threshold {
                        if t.since == nil { t.since = now }
                        let held = now.timeIntervalSince(t.since ?? now)
                        let recentlyFired = t.lastFired.map { now.timeIntervalSince($0) < Self.renotifyInterval } ?? false
                        if held >= rule.sustainedSeconds, !recentlyFired {
                            fire(rule, on: p, value: value, protected: protected, store: store)
                            t.lastFired = now
                            if rule.action == .terminate, !protected.contains(p.name) { t.terminatedAt = now }
                        }
                    } else {
                        t.since = nil
                    }
                    tracking[key] = t
                }
            }
        }
        tracking = tracking.filter { live.contains($0.key) }
    }

    private func fire(_ rule: Rule, on p: ProcessSample, value: Double, protected: Set<String>, store: RuleStore) {
        let what = "\(p.name) (pid \(p.pid)) \(rule.metric.label.lowercased()) \(rule.format(value)) ≥ \(rule.format(rule.threshold))"
        switch rule.action {
        case .notify:
            store.log(.warning, "\(rule.label): \(what)")
            if rule.notify { Notifier.send(title: rule.label, body: what) }
        case .terminate, .kill:
            if protected.contains(p.name) {
                store.log(.warning, "\(rule.label): \(what) — not touched, \(p.name) is protected")
                if rule.notify { Notifier.send(title: "\(rule.label) (protected)", body: what) }
                return
            }
            let signal = rule.action == .kill ? SIGKILL : SIGTERM
            let signalName = rule.action == .kill ? "SIGKILL" : "SIGTERM"
            if kill(p.pid, signal) == 0 {
                store.log(.action, "\(rule.label): sent \(signalName) to \(what)")
                if rule.notify { Notifier.send(title: "\(rule.label): \(signalName) \(p.name)", body: what) }
            } else {
                let err = String(cString: strerror(errno))
                store.log(.error, "\(rule.label): \(signalName) \(p.name) (pid \(p.pid)) failed: \(err)")
                if rule.notify { Notifier.send(title: "\(rule.label): failed to \(rule.action.shortLabel) \(p.name)", body: err) }
            }
        }
    }
}
