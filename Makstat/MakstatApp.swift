import SwiftUI
import AppKit
import UserNotifications

@main
struct MakstatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = Monitor.shared
    @AppStorage(PrefKey.menuBarStyle) private var menuBarStyle = MenuBarStyle.cpu.rawValue

    init() {
        Prefs.register()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(monitor)
                .environmentObject(monitor.store)
        } label: {
            MenuBarLabel(style: MenuBarStyle(rawValue: menuBarStyle) ?? .cpu)
                .environmentObject(monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(monitor)
                .environmentObject(monitor.store)
        }
    }
}

extension Monitor {
    static let shared = Monitor()
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var debugWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            Monitor.shared.start()
            if Monitor.shared.store.rules.contains(where: { $0.enabled && $0.notify }) {
                Notifier.requestAuthorization()
            }
            // `Makstat --window` shows the popover content in a regular window (handy for screenshots).
            if CommandLine.arguments.contains("--window") { showWindow() }
            // `Makstat --screenshot <dir>` renders every screen to PNG files and exits.
            if let i = CommandLine.arguments.firstIndex(of: "--screenshot"), i + 1 < CommandLine.arguments.count {
                ScreenshotMode.run(directory: CommandLine.arguments[i + 1])
            }
        }
    }

    @MainActor private func showWindow() {
        let view = MenuView().environmentObject(Monitor.shared).environmentObject(Monitor.shared.store)
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 700),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Makstat"
        w.contentView = NSHostingView(rootView: view)
        w.setFrameTopLeftPoint(NSPoint(x: 100, y: (NSScreen.main?.frame.height ?? 900) - 60))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = w
        print("window: \(w.windowNumber)")
        fflush(stdout)
    }

    // Show banners even while the app is "active" (menu bar apps usually are).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject private var monitor: Monitor
    let style: MenuBarStyle

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            if style != .icon {
                Text(Format.percent(monitor.snapshot.cpu.usage))
                    .monospacedDigit()
            }
            if style == .cpuMemory {
                Text(Format.bytes(monitor.snapshot.memory.used, decimals: 0))
                    .monospacedDigit()
            }
        }
    }
}
