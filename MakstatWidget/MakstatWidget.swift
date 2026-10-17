import WidgetKit
import SwiftUI
import AppIntents

@main
struct MakstatWidgetBundle: WidgetBundle {
    var body: some Widget {
        MakstatWidget()
    }
}

enum WidgetSort: String, AppEnum {
    case cpu, memory
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sort processes by")
    static var caseDisplayRepresentations: [WidgetSort: DisplayRepresentation] = [
        .cpu: "CPU", .memory: "Memory",
    ]
    var processSort: ProcessSort { self == .cpu ? .cpu : .memory }
}

struct MakstatConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Makstat"
    static var description = IntentDescription("System status and the heaviest processes by name.")

    @Parameter(title: "Sort processes by", default: .cpu)
    var sort: WidgetSort
}

struct MakstatEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
    let sort: ProcessSort
    let live: Bool   // true when the app wrote the snapshot, false when the widget sampled itself
}

struct MakstatProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MakstatEntry {
        MakstatEntry(date: Date(), snapshot: Self.sampleSnapshot(), sort: .cpu, live: false)
    }

    func snapshot(for configuration: MakstatConfigIntent, in context: Context) async -> MakstatEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: MakstatConfigIntent, in context: Context) async -> Timeline<MakstatEntry> {
        let e = entry(for: configuration)
        return Timeline(entries: [e], policy: .after(Date().addingTimeInterval(300)))
    }

    private func entry(for configuration: MakstatConfigIntent) -> MakstatEntry {
        // Prefer what the app wrote recently; otherwise sample what the sandbox lets us see.
        if let s = SharedStore.read(), Date().timeIntervalSince(s.timestamp) < 3600 {
            return MakstatEntry(date: s.timestamp, snapshot: s, sort: configuration.sort.processSort, live: true)
        }
        return MakstatEntry(date: Date(), snapshot: Self.sampleSnapshot(), sort: configuration.sort.processSort, live: false)
    }

    static func sampleSnapshot() -> Snapshot {
        let sys = SystemSampler()
        let procs = ProcessSampler()
        _ = sys.sample(); _ = procs.sample()
        Thread.sleep(forTimeInterval: 0.5)
        var s = Snapshot()
        let r = sys.sample()
        s.cpu = r.cpu; s.memory = r.memory; s.disk = r.disk; s.network = r.network
        let p = procs.sample()
        s.groups = p.groups; s.processCount = p.processCount; s.hiddenProcessCount = p.hidden
        s.uptime = ProcessInfo.processInfo.systemUptime
        return s.trimmed()
    }
}

struct MakstatWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.magicaltux.makstat.widget", intent: MakstatConfigIntent.self, provider: MakstatProvider()) { entry in
            MakstatWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Makstat")
        .description("CPU, memory, disk and the heaviest processes grouped by name.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MakstatWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MakstatEntry

    var body: some View {
        if let s = entry.snapshot {
            switch family {
            case .systemSmall: small(s)
            case .systemMedium: medium(s)
            default: large(s)
            }
        } else {
            Text("Open Makstat to start sampling.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func small(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            gauge("CPU", fraction: s.cpu.usage / 100, text: Format.percent(s.cpu.usage))
            gauge("MEM", fraction: s.memory.usedFraction, text: Format.bytes(s.memory.used, decimals: 0))
            if let v = s.disk.volumes.first {
                gauge("DISK", fraction: v.usedFraction, text: "\(Format.diskBytes(v.free)) free")
            }
            Spacer(minLength: 0)
            ForEach(s.topGroups(by: entry.sort, limit: 2)) { g in
                HStack {
                    Text(g.name).lineLimit(1)
                    Spacer()
                    Text(entry.sort == .cpu ? Format.percent(g.cpu) : Format.bytes(g.memory, decimals: 0))
                }
                .font(.caption2).monospacedDigit()
            }
            stamp
        }
    }

    private func medium(_ s: Snapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                gauge("CPU", fraction: s.cpu.usage / 100, text: Format.percent(s.cpu.usage))
                gauge("MEM", fraction: s.memory.usedFraction, text: "\(Format.bytes(s.memory.used, decimals: 0)) / \(Format.bytes(s.memory.total, decimals: 0))")
                if let v = s.disk.volumes.first {
                    gauge("DISK", fraction: v.usedFraction, text: "\(Format.diskBytes(v.free)) free")
                }
                Spacer(minLength: 0)
                HStack {
                    Text("↓\(Format.rate(s.network.inRate))")
                    Text("↑\(Format.rate(s.network.outRate))")
                }.font(.caption2).foregroundStyle(.secondary)
                stamp
            }
            .frame(width: 130)
            processList(s, limit: 6)
        }
    }

    private func large(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                gauge("CPU", fraction: s.cpu.usage / 100, text: Format.percent(s.cpu.usage))
                gauge("MEM", fraction: s.memory.usedFraction, text: Format.bytes(s.memory.used, decimals: 0))
                if let v = s.disk.volumes.first {
                    gauge("DISK", fraction: v.usedFraction, text: "\(Format.diskBytes(v.free)) free")
                }
            }
            HStack {
                Text("load \(String(format: "%.1f", s.cpu.loadAverage[0]))")
                Text("pressure \(s.memory.pressure.label.lowercased())")
                Text("disk ↓\(Format.rate(s.disk.readRate)) ↑\(Format.rate(s.disk.writeRate))")
                Text("net ↓\(Format.rate(s.network.inRate)) ↑\(Format.rate(s.network.outRate))")
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Divider()
            processList(s, limit: 14)
            Spacer(minLength: 0)
            stamp
        }
    }

    private func processList(_ s: Snapshot, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU").frame(width: 46, alignment: .trailing)
                Text("Mem").frame(width: 58, alignment: .trailing)
            }
            .font(.caption2).foregroundStyle(.tertiary)
            ForEach(s.topGroups(by: entry.sort, limit: limit)) { g in
                HStack {
                    HStack(spacing: 3) {
                        Text(g.name).lineLimit(1).truncationMode(.middle)
                        if g.count > 1 { Text("×\(g.count)").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Format.percent(g.cpu)).frame(width: 46, alignment: .trailing)
                    Text(Format.bytes(g.memory, decimals: g.memory < (1 << 30) ? 0 : 1)).frame(width: 58, alignment: .trailing)
                }
                .font(.caption).monospacedDigit()
            }
        }
    }

    private func gauge(_ label: String, fraction: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Text(text).font(.caption2).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(fraction > 0.9 ? Color.red : fraction > 0.7 ? Color.orange : Color.accentColor)
                        .frame(width: geo.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 6)
        }
    }

    private var stamp: some View {
        Text((entry.live ? "" : "widget sample · ") + Format.shortTime.string(from: entry.date))
            .font(.system(size: 9)).foregroundStyle(.tertiary)
    }
}
