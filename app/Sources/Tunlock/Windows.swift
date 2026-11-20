import AppKit
import SwiftUI

/// Plain AppKit windows: reliable in a menu bar-only app.
@MainActor
final class Windows {
    static let shared = Windows()
    private var windows: [String: NSWindow] = [:]

    func showSettings() {
        show("settings", title: L("Tunlock Settings", "Настройки Tunlock")) { SettingsView() }
    }

    func close(_ id: String) {
        windows[id]?.close()
        windows[id] = nil
    }

    func showAgent() {
        show("agent", title: L("AI agent (MCP)", "ИИ-агент (MCP)")) { AgentView() }
    }

    func showLeakTest() {
        windows["leaktest"]?.close()
        windows["leaktest"] = nil
        show("leaktest", title: L("Leak test", "Тест утечек")) { LeakTestView() }
    }

    private func show<V: View>(_ id: String, title: String, content: () -> V) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: content().environmentObject(StatusModel.shared))
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
    }
}
