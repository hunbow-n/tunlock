import AppKit
import SwiftUI

/// `Tunlock --mcp` runs the MCP server for AI agents instead of the menu bar app.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--mcp") { MCPServer.run() }
        TunlockApp.main()
    }
}

struct TunlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = StatusModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // First launch: nothing to show in the menu yet, so open the setup.
        // First launch, or an agent's draft waiting: open the settings once the model exists.
        if !StatusModel.shared.installed || StatusModel.shared.draftID != nil { Windows.shared.showSettings() }
        if Notifier.enabled { Notifier.requestPermission() }
    }
}

/// Shield by state; with a verified exit, optionally the country flag next to it.
struct MenuBarLabel: View {
    @EnvironmentObject var model: StatusModel
    @AppStorage("showFlag") private var showFlag = true

    var body: some View {
        let v = model.verdict
        let country = model.state["egress_country"] ?? ""
        HStack(spacing: 3) {
            Image(systemName: v.symbol)
            if showFlag, v == .protected, !country.isEmpty { Text(flagEmoji(country)) }
        }
        .accessibilityLabel("Tunlock: " + v.title)
    }
}
