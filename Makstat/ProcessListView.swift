import SwiftUI

struct ProcessListView: View {
    @EnvironmentObject private var monitor: Monitor
    @AppStorage(PrefKey.processSort) private var sortRaw = ProcessSort.cpu.rawValue
    @AppStorage(PrefKey.processLimit) private var limit = 12
    @State private var expanded: Set<String> = []
    @State private var showAll = false

    private var sort: ProcessSort { ProcessSort(rawValue: sortRaw) ?? .cpu }

    var body: some View {
        let groups = monitor.snapshot.topGroups(by: sort, limit: showAll ? 60 : limit)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Processes by name").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $sortRaw) {
                    ForEach(ProcessSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 180)
            }
            columnHeader
            ForEach(groups) { g in
                GroupRow(group: g, sort: sort, expanded: expanded.contains(g.name)) {
                    if expanded.contains(g.name) { expanded.remove(g.name) } else { expanded.insert(g.name) }
                }
            }
            HStack {
                Spacer()
                Button(showAll ? "Show fewer" : "Show more") { showAll.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 6) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: 56, alignment: .trailing)
            Text("Memory").frame(width: 66, alignment: .trailing)
            if sort == .disk {
                Text("Disk R/W").frame(width: 120, alignment: .trailing)
            }
        }
        .font(.caption2).foregroundStyle(.tertiary)
        .padding(.leading, 14)
    }
}

private struct GroupRow: View {
    @EnvironmentObject private var monitor: Monitor
    let group: ProcessGroup
    let sort: ProcessSort
    let expanded: Bool
    let toggle: () -> Void
    @State private var args: [pid_t: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary).frame(width: 8)
                    Text(group.name).lineLimit(1).truncationMode(.middle)
                    if group.count > 1 {
                        Text("×\(group.count)").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).background(Color.primary.opacity(0.08)).clipShape(Capsule())
                    }
                    if !group.detailed {
                        Image(systemName: "lock").font(.caption2).foregroundStyle(.tertiary)
                            .help("Owned by another user; details need root")
                    }
                    Spacer(minLength: 4)
                    Text(Format.percent(group.cpu, decimals: group.cpu < 10 ? 1 : 0))
                        .frame(width: 56, alignment: .trailing).foregroundStyle(group.cpu >= 100 ? .orange : .primary)
                    Text(Format.bytes(group.memory)).frame(width: 66, alignment: .trailing)
                    if sort == .disk {
                        Text("\(Format.rate(group.diskRead)) / \(Format.rate(group.diskWrite))")
                            .frame(width: 120, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .font(.callout).monospacedDigit()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if group.detailed {
                    Button("Terminate all \(group.name) (SIGTERM)") { group.processes.forEach { monitor.signal($0, SIGTERM) } }
                    Button("Kill all \(group.name) (SIGKILL)") { group.processes.forEach { monitor.signal($0, SIGKILL) } }
                }
                if let path = group.processes.first?.path {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            }

            if expanded {
                ForEach(group.processes.sorted(by: sort.processOrder).prefix(25)) { p in
                    ProcessRow(process: p, args: args[p.pid])
                        .onAppear { loadArgs(p.pid) }
                }
                .padding(.leading, 14)
            }
        }
    }

    private func loadArgs(_ pid: pid_t) {
        guard args[pid] == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let a = ProcessSampler.arguments(of: pid)?.dropFirst().joined(separator: " ") ?? ""
            DispatchQueue.main.async { args[pid] = a }
        }
    }
}

private struct ProcessRow: View {
    @EnvironmentObject private var monitor: Monitor
    let process: ProcessSample
    let args: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(process.pid)").foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text(args?.isEmpty == false ? args! : (process.path ?? process.name))
                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                .help((process.path ?? "") + (args.map { "\n" + $0 } ?? ""))
            Spacer(minLength: 4)
            if process.detailed {
                Text("\(process.threads) thr").foregroundStyle(.tertiary)
                Text(Format.percent(process.cpu, decimals: process.cpu < 10 ? 1 : 0)).frame(width: 56, alignment: .trailing)
                Text(Format.bytes(process.memory)).frame(width: 66, alignment: .trailing)
                Menu {
                    Button("Terminate (SIGTERM)") { monitor.signal(process, SIGTERM) }
                    Button("Kill (SIGKILL)") { monitor.signal(process, SIGKILL) }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                .help("Terminate or kill this process")
            } else {
                Text("uid \(process.uid)").foregroundStyle(.tertiary)
            }
        }
        .font(.caption).monospacedDigit()
    }
}
