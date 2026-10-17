import AppKit
import SwiftUI

/// Renders each screen of the app to PNG files (used by CI to produce visual artifacts).
/// Rendering goes through AppKit's display cache, so no screen-recording permission is needed.
@MainActor
enum ScreenshotMode {
    static func run(directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let monitor = Monitor.shared
        monitor.popoverVisible = true

        // A throwaway store so the rules/events screens have content without touching user data.
        let demoDir = FileManager.default.temporaryDirectory.appendingPathComponent("makstat-demo-\(getpid())")
        let demo = RuleStore(directory: demoDir)
        var r1 = Rule(); r1.label = "Runaway rustc"; r1.pattern = "rustc"; r1.metric = .memory
        r1.threshold = 16 * 1_073_741_824; r1.action = .terminate
        var r2 = Rule(); r2.label = "CPU hog"; r2.pattern = "*"; r2.metric = .cpu
        r2.threshold = 800; r2.sustainedSeconds = 300; r2.action = .notify
        demo.rules = [r1, r2]
        demo.log(.warning, "CPU hog: cargo (pid 4242) cpu 812% ≥ 800%")
        demo.log(.action, "Runaway rustc: sent SIGTERM to rustc (pid 4311) memory 16.4 GB ≥ 16 GB")
        demo.log(.action, "Manual: sent SIGKILL to node (pid 5120)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            let live = { (v: AnyView) in v.environmentObject(monitor).environmentObject(monitor.store) }
            let demoEnv = { (v: AnyView) in v.environmentObject(monitor).environmentObject(demo) }
            capture(live(AnyView(MenuView())), width: 400, name: "popover", in: dir)
            capture(live(AnyView(SettingsView(tab: .general))), width: 680, height: 460, name: "settings-general", in: dir)
            capture(demoEnv(AnyView(SettingsView(tab: .rules, selectedRule: r1.id))), width: 680, height: 460, name: "settings-rules", in: dir)
            capture(demoEnv(AnyView(SettingsView(tab: .events))), width: 680, height: 460, name: "settings-events", in: dir)
            try? FileManager.default.removeItem(at: demoDir)
            print("screenshots written to \(dir.path)")
            exit(0)
        }
    }

    private static func capture<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, name: String, in dir: URL) {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? 10)
        host.layoutSubtreeIfNeeded()
        let size = CGSize(width: width, height: height ?? host.fittingSize.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        // Give SwiftUI a chance to finish layout passes before caching.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        window.orderOut(nil)
    }
}
