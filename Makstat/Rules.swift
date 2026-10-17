import Foundation

enum RuleMetric: String, Codable, CaseIterable, Identifiable {
    case memory, cpu
    var id: String { rawValue }
    var label: String { self == .memory ? "Memory" : "CPU" }
}

enum RuleAction: String, Codable, CaseIterable, Identifiable {
    case notify, terminate, kill
    var id: String { rawValue }
    var label: String {
        switch self {
        case .notify: return "Notify only"
        case .terminate: return "Terminate (SIGTERM, then SIGKILL after 10 s)"
        case .kill: return "Kill (SIGKILL)"
        }
    }
    var shortLabel: String {
        switch self {
        case .notify: return "notify"
        case .terminate: return "terminate"
        case .kill: return "kill"
        }
    }
}

struct Rule: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    var label = "New rule"
    /// Glob matched against the process name (or the full path when the pattern contains "/").
    var pattern = "*"
    var metric: RuleMetric = .memory
    /// Bytes for memory, percent of one core for CPU.
    var threshold: Double = 8 * 1024 * 1024 * 1024
    /// Seconds the condition must hold before the action fires. 0 = immediately.
    var sustainedSeconds: Double = 0
    var action: RuleAction = .notify
    var notify = true

    func matches(_ p: ProcessSample) -> Bool {
        if pattern.isEmpty || pattern == "*" { return true }
        if pattern.contains("/") {
            guard let path = p.path else { return false }
            return fnmatch(pattern, path, 0) == 0
        }
        return fnmatch(pattern, p.name, FNM_CASEFOLD) == 0
    }

    func value(of p: ProcessSample) -> Double {
        metric == .memory ? Double(p.memory) : p.cpu
    }

    func format(_ value: Double) -> String {
        metric == .memory ? Format.bytes(value) : Format.percent(value)
    }

    var thresholdDescription: String {
        "\(metric.label) ≥ \(format(threshold))" + (sustainedSeconds > 0 ? " for \(Int(sustainedSeconds)) s" : "")
    }
}

struct Event: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case info, warning, action, error }
    var id = UUID()
    var date = Date()
    var kind: Kind
    var text: String
}

/// Persists rules and the event log under ~/Library/Application Support/Makstat.
@MainActor
final class RuleStore: ObservableObject {
    @Published var rules: [Rule] { didSet { save(rules, to: rulesURL) } }
    @Published var events: [Event] { didSet { save(events, to: eventsURL) } }

    private let directory: URL
    private var rulesURL: URL { directory.appendingPathComponent("rules.json") }
    private var eventsURL: URL { directory.appendingPathComponent("events.json") }
    static let maxEvents = 500

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Makstat", isDirectory: true)
    }

    init(directory: URL = RuleStore.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rules = Self.load([Rule].self, from: directory.appendingPathComponent("rules.json")) ?? []
        events = Self.load([Event].self, from: directory.appendingPathComponent("events.json")) ?? []
    }

    func log(_ kind: Event.Kind, _ text: String) {
        events.insert(Event(kind: kind, text: text), at: 0)
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }
}
