import Foundation
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, cpu, cpuMemory
    var id: String { rawValue }
    var label: String {
        switch self {
        case .icon: return "Icon only"
        case .cpu: return "Icon + CPU %"
        case .cpuMemory: return "Icon + CPU % + memory"
        }
    }
}

enum PrefKey {
    static let sampleInterval = "sampleInterval"          // seconds, while popover closed
    static let menuBarStyle = "menuBarStyle"
    static let processLimit = "processLimit"
    static let processSort = "processSort"
    static let widgetRefresh = "widgetRefresh"            // seconds
    static let protectedNames = "protectedNames"
    static let showPerCore = "showPerCore"
}

enum Prefs {
    static let defaults: [String: Any] = [
        PrefKey.sampleInterval: 3.0,
        PrefKey.menuBarStyle: MenuBarStyle.cpu.rawValue,
        PrefKey.processLimit: 12,
        PrefKey.processSort: ProcessSort.cpu.rawValue,
        PrefKey.widgetRefresh: 300.0,
        PrefKey.protectedNames: "Makstat, Terminal, iTerm2, WindowServer, loginwindow, Finder, Dock, SystemUIServer, launchd, kernel_task",
        PrefKey.showPerCore: true,
    ]

    static func register() {
        UserDefaults.standard.register(defaults: defaults)
    }

    static var protectedNames: Set<String> {
        let raw = UserDefaults.standard.string(forKey: PrefKey.protectedNames) ?? ""
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launch at login: \(error)")
            }
        }
    }
}
