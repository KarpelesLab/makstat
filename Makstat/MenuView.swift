import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var monitor: Monitor
    @Environment(\.openSettings) private var openSettings
    @AppStorage(PrefKey.showPerCore) private var showPerCore = true

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            header(s)
            cpuSection(s)
            memorySection(s)
            diskSection(s)
            networkSection(s)
            Divider()
            ProcessListView()
            Divider()
            footer(s)
        }
        .padding(12)
        .frame(width: 400)
        .onAppear { monitor.popoverVisible = true }
        .onDisappear { monitor.popoverVisible = false }
    }

    private func header(_ s: Snapshot) -> some View {
        HStack {
            Text("Makstat").font(.headline)
            Spacer()
            Text("up \(Format.duration(s.uptime))").font(.caption).foregroundStyle(.secondary)
            Button { openSettingsWindow() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Settings and rules")
        }
    }

    private func cpuSection(_ s: Snapshot) -> some View {
        StatSection(title: "CPU", trailing: "\(Format.percent(s.cpu.usage)) · \(s.cpu.coreCount) cores · load \(String(format: "%.1f %.1f %.1f", s.cpu.loadAverage[0], s.cpu.loadAverage[1], s.cpu.loadAverage[2]))") {
            HStack(spacing: 8) {
                SegmentBar(segments: [(s.cpu.user / 100, .cpuUser), (s.cpu.system / 100, .cpuSystem)])
                Sparkline(values: monitor.cpuHistory, color: .cpuUser).frame(width: 90, height: 20)
            }
            HStack {
                Stat(label: "user", value: Format.percent(s.cpu.user))
                Stat(label: "sys", value: Format.percent(s.cpu.system))
                Spacer()
                Stat(label: "idle", value: Format.percent(max(0, 100 - s.cpu.usage)))
            }
            if showPerCore, !s.cpu.perCore.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(s.cpu.perCore.enumerated()), id: \.offset) { _, v in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.usage(v / 100).opacity(0.25 + 0.75 * v / 100))
                            .frame(height: 6)
                    }
                }
                .help("Per-core usage")
            }
        }
    }

    private func memorySection(_ s: Snapshot) -> some View {
        let m = s.memory
        let t = Double(max(m.total, 1))
        return StatSection(title: "Memory", trailing: "\(Format.bytes(m.used)) of \(Format.bytes(m.total, decimals: 0)) · pressure \(m.pressure.label.lowercased())") {
            HStack(spacing: 8) {
                SegmentBar(segments: [(Double(m.app) / t, .memApp), (Double(m.wired) / t, .memWired), (Double(m.compressed) / t, .memCompressed)])
                Sparkline(values: monitor.memoryHistory, color: .memApp).frame(width: 90, height: 20)
            }
            HStack {
                Stat(label: "app", value: Format.bytes(m.app))
                Stat(label: "wired", value: Format.bytes(m.wired))
                Stat(label: "comp", value: Format.bytes(m.compressed))
                Stat(label: "cached", value: Format.bytes(m.cached))
                Spacer()
                if m.swapUsed > 0 { Stat(label: "swap", value: Format.bytes(m.swapUsed)) }
            }
        }
        .foregroundStyle(m.pressure == .critical ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
    }

    private func diskSection(_ s: Snapshot) -> some View {
        StatSection(title: "Disk", trailing: "read \(Format.rate(s.disk.readRate)) · write \(Format.rate(s.disk.writeRate))") {
            ForEach(s.disk.volumes.prefix(4)) { v in
                HStack(spacing: 8) {
                    Text(v.name).font(.caption).lineLimit(1).frame(width: 110, alignment: .leading)
                    SegmentBar(segments: [(v.usedFraction, Color.usage(v.usedFraction))], height: 6)
                    Text("\(Format.diskBytes(v.free)) free of \(Format.diskBytes(v.total))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .trailing)
                }
            }
        }
    }

    private func networkSection(_ s: Snapshot) -> some View {
        HStack {
            Text("Network").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Spacer()
            Stat(label: "↓", value: Format.rate(s.network.inRate))
            Stat(label: "↑", value: Format.rate(s.network.outRate))
        }
    }

    private func footer(_ s: Snapshot) -> some View {
        HStack {
            Text("\(s.processCount) processes" + (s.hiddenProcessCount > 0 ? " · \(s.hiddenProcessCount) hidden" : ""))
                .font(.caption).foregroundStyle(.secondary)
                .help("Hidden processes belong to other users (including root) and cannot be inspected without elevated privileges.")
            Spacer()
            Button("Activity Monitor") {
                let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }.font(.caption).buttonStyle(.link)
            Button("Rules…") { openSettingsWindow() }.font(.caption).buttonStyle(.link)
            Button("Quit") { NSApp.terminate(nil) }.font(.caption).buttonStyle(.link)
        }
    }

    private func openSettingsWindow() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}
