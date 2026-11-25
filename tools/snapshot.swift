// Renders the app's views to PNG files for docs and review, without a display.
// Built by tools/snapshot.sh together with the app sources (minus @main).
import AppKit
import SwiftUI

/// A window that reports the scale SNAPSHOT_SCALE asks for (default 1), so AppKit and SwiftUI draw text,
/// symbols and shapes at that scale even with no Retina screen attached: sharp copies for the website.
final class ScaledWindow: NSWindow {
    var scale: CGFloat = 1
    override var backingScaleFactor: CGFloat { scale }
}

@MainActor
func snapshot<V: View>(_ view: V, _ path: String) {
    let host = NSHostingView(rootView: view.environmentObject(StatusModel.shared))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = ScaledWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.scale = CGFloat(max(1, Int(ProcessInfo.processInfo.environment["SNAPSHOT_SCALE"] ?? "") ?? 1))
    window.contentView = host
    window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["DARK"] == nil ? .aqua : .darkAqua)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

@main
enum Snapshot {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let out = CommandLine.arguments[1]
        let proxy = ProcessInfo.processInfo.environment["SNAPSHOT_PROXY"] != nil
        UserDefaults.standard.set(proxy ? "" : (isRussian ? "Варшава" : "Warsaw"), forKey: HopNames.entryKey)
        UserDefaults.standard.set(proxy ? (isRussian ? "Нью-Йорк" : "New York") : (isRussian ? "Амстердам" : "Amsterdam"),
                                  forKey: HopNames.exitKey)
        StatusModel.shared.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        StatusModel.shared.refresh()
        snapshot(MenuView().background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: Shape.panelRadius, style: .continuous)), out + "-menu.png")
        if ProcessInfo.processInfo.environment["SNAPSHOT_MENU_ONLY"] != nil { return }
        snapshot(SettingsView(), out + "-settings.png")
        snapshot(SettingsView(tab: .exit), out + "-exit.png")
        snapshot(SettingsView(tab: .activity), out + "-activity.png")
        snapshot(AgentView().background(Color(nsColor: .windowBackgroundColor)), out + "-agent.png")
        if let draft = ProcessInfo.processInfo.environment["TUNLOCK_UI_DRAFT"] {
            try? String(contentsOfFile: Paths.config, encoding: .utf8).write(toFile: draft, atomically: true, encoding: .utf8)
            snapshot(SettingsView(), out + "-review.png")
            try? FileManager.default.removeItem(atPath: draft)
        }
        StatusModel.shared.testOutput = """
        Mode: protected, physical interface: en0, expected egress: 203.0.113.10
        PASS  pf enabled, tunlock rules loaded                 ok
        PASS  tunnel HTTPS by IP (1.1.1.1)                     ok (203.0.113.10)
        PASS  HTTPS by name, system DNS and route              ok (203.0.113.10)
        PASS  direct IPv4 TCP on en0, no DNS                   fail
        PASS  direct UDP DNS to 1.1.1.1 on en0                 fail
        SKIP  IPv6                                             no IPv6 address on en0: run again on a network with IPv6
        SKIPPED=1
        RESULT=pass
        """
        snapshot(LeakTestView().background(Color(nsColor: .windowBackgroundColor)), out + "-leaktest.png")
    }
}
