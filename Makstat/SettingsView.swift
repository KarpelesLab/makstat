import SwiftUI

enum SettingsTab: String, Hashable { case general, rules, events }

struct SettingsView: View {
    @State private var tab: SettingsTab
    private let initialRule: UUID?

    init(tab: SettingsTab = .general, selectedRule: UUID? = nil) {
        _tab = State(initialValue: tab)
        initialRule = selectedRule
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            RulesSettings(selectedRule: initialRule).tabItem { Label("Rules", systemImage: "shield.lefthalf.filled") }.tag(SettingsTab.rules)
            EventsSettings().tabItem { Label("Events", systemImage: "list.bullet.rectangle") }.tag(SettingsTab.events)
        }
        .frame(width: 680, height: 460)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var monitor: Monitor
    @AppStorage(PrefKey.sampleInterval) private var sampleInterval = 3.0
    @AppStorage(PrefKey.menuBarStyle) private var menuBarStyle = MenuBarStyle.cpu.rawValue
    @AppStorage(PrefKey.processLimit) private var processLimit = 12
    @AppStorage(PrefKey.widgetRefresh) private var widgetRefresh = 300.0
    @AppStorage(PrefKey.protectedNames) private var protectedNames = ""
    @AppStorage(PrefKey.showPerCore) private var showPerCore = true
    @State private var launchAtLogin = Prefs.launchAtLogin

    var body: some View {
        Form {
            Picker("Menu bar shows", selection: $menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0.rawValue) }
            }
            Toggle("Show per-core usage", isOn: $showPerCore)
            LabeledContent("Background sampling") {
                HStack {
                    Slider(value: $sampleInterval, in: 1...15, step: 1)
                    Text("every \(Int(sampleInterval)) s").monospacedDigit().frame(width: 80, alignment: .trailing)
                }
            }
            Text("Rules are checked at this rate. The popover samples every 1.5 s while open.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Processes listed: \(processLimit)", value: $processLimit, in: 5...40)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in Prefs.launchAtLogin = v; launchAtLogin = Prefs.launchAtLogin }

            Divider()
            LabeledContent("Widget refresh") {
                HStack {
                    Slider(value: $widgetRefresh, in: 60...1800, step: 60)
                    Text("every \(Int(widgetRefresh / 60)) min").monospacedDigit().frame(width: 90, alignment: .trailing)
                }
            }
            HStack {
                Text("WidgetKit limits how often widgets reload, so the widget always lags behind the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh widget now") { monitor.refreshWidgetNow() }
            }

            Divider()
            TextField("Protected processes", text: $protectedNames)
            Text("Comma-separated names that rules will never terminate or kill.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

struct RulesSettings: View {
    @EnvironmentObject private var store: RuleStore
    @State private var selection: UUID?

    init(selectedRule: UUID? = nil) {
        _selection = State(initialValue: selectedRule)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.rules) { rule in
                        HStack {
                            Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(rule.enabled ? Color.accentColor : .secondary)
                            VStack(alignment: .leading) {
                                Text(rule.label)
                                Text("\(rule.pattern) · \(rule.thresholdDescription) → \(rule.action.shortLabel)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(rule.id)
                    }
                }
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    Divider().frame(height: 16)
                    Button { remove() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(minWidth: 240, idealWidth: 260)

            Group {
                if let i = store.rules.firstIndex(where: { $0.id == selection }) {
                    RuleEditor(rule: $store.rules[i])
                } else {
                    VStack(spacing: 8) {
                        Text("Rules watch every process you own and act when a threshold is crossed.")
                        Text("Add a rule with the + button, e.g. kill any rustc using more than 16 GB.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout).multilineTextAlignment(.center).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360)
        }
    }

    private func add() {
        var r = Rule()
        r.label = "Rule \(store.rules.count + 1)"
        store.rules.append(r)
        selection = r.id
        Notifier.requestAuthorization()
    }

    private func remove() {
        guard let sel = selection else { return }
        store.rules.removeAll { $0.id == sel }
        selection = nil
    }
}

struct RuleEditor: View {
    @Binding var rule: Rule
    private static let units: [(String, Double)] = [("MB", 1_048_576), ("GB", 1_073_741_824)]

    var body: some View {
        Form {
            TextField("Label", text: $rule.label)
            Toggle("Enabled", isOn: $rule.enabled)
            TextField("Process name", text: $rule.pattern, prompt: Text("* for any process"))
            Text("Glob, case-insensitive: rustc, cargo*, *test*. Use a / to match the full path instead.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Watch", selection: $rule.metric) {
                ForEach(RuleMetric.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: rule.metric) { _, m in
                rule.threshold = m == .memory ? 8 * Self.gb : 200
            }
            if rule.metric == .memory {
                LabeledContent("Threshold") {
                    HStack {
                        TextField("", value: memoryValue, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 90)
                        Picker("", selection: memoryUnit) {
                            ForEach(Self.units, id: \.0) { Text($0.0).tag($0.1) }
                        }
                        .labelsHidden().frame(width: 70)
                    }
                }
                Text("Per process, physical footprint as shown by Activity Monitor.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                LabeledContent("Threshold") {
                    HStack {
                        TextField("", value: $rule.threshold, format: .number.precision(.fractionLength(0)))
                            .frame(width: 90)
                        Text("%").foregroundStyle(.secondary)
                    }
                }
                Text("Percent of one core, per process: 400 means four cores busy.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Sustained for") {
                HStack {
                    TextField("", value: $rule.sustainedSeconds, format: .number.precision(.fractionLength(0)))
                        .frame(width: 90)
                    Text("seconds").foregroundStyle(.secondary)
                }
            }
            Text("How long the condition must hold before acting. 0 acts at once.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Action", selection: $rule.action) {
                ForEach(RuleAction.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Send a notification", isOn: $rule.notify)
            Text("Protected names (General tab) are never signalled; such hits are only logged.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private static let mb = 1_048_576.0
    private static let gb = 1_073_741_824.0

    private var memoryUnit: Binding<Double> {
        Binding(get: { rule.threshold >= Self.gb ? Self.gb : Self.mb },
                set: { unit in
                    let value = rule.threshold / (rule.threshold >= Self.gb ? Self.gb : Self.mb)
                    rule.threshold = value * unit
                })
    }

    private var memoryValue: Binding<Double> {
        Binding(get: { rule.threshold / memoryUnit.wrappedValue },
                set: { rule.threshold = $0 * memoryUnit.wrappedValue })
    }
}

struct EventsSettings: View {
    @EnvironmentObject private var store: RuleStore

    var body: some View {
        VStack(spacing: 0) {
            if store.events.isEmpty {
                Text("No events yet. Rule hits and manual kills show up here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.events) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(e.kind)).foregroundStyle(color(e.kind)).frame(width: 16)
                        Text(e.date, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        Text(e.text).textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
            HStack {
                Spacer()
                Button("Clear") { store.events.removeAll() }.disabled(store.events.isEmpty)
            }
            .padding(8)
        }
    }

    private func icon(_ k: Event.Kind) -> String {
        switch k {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .action: return "bolt.fill"
        case .error: return "xmark.octagon"
        }
    }

    private func color(_ k: Event.Kind) -> Color {
        switch k {
        case .info: return .secondary
        case .warning: return .orange
        case .action: return .red
        case .error: return .red
        }
    }
}
