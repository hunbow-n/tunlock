import AppKit
import SwiftUI

/// How to let an AI agent set Tunlock up: what it may do, and one copy-paste per client.
struct AgentView: View {
    @State private var copied: String?

    private var exe: String {
        ProcessInfo.processInfo.environment["TUNLOCK_UI_EXE"]  // docs screenshots only
            ?? Bundle.main.executablePath ?? "/Applications/Tunlock.app/Contents/MacOS/Tunlock"
    }
    private var inApplications: Bool { exe.hasPrefix("/Applications/") }

    private var claudeCode: String { "claude mcp add tunlock -- \"\(exe)\" --mcp" }
    private var jsonConfig: String {
        """
        {
          "mcpServers": {
            "tunlock": { "command": "\(exe)", "args": ["--mcp"] }
          }
        }
        """
    }
    private var prompt: String {
        L("Set up Tunlock on my Mac with the tunlock MCP tools. Start with detect, ask me what I have (my server or a proxy), check everything, and propose a config for me to review.",
          "Настрой Tunlock на моём Mac через MCP-инструменты tunlock. Начни с detect, спроси, что у меня есть (свой сервер или прокси), всё проверь и предложи конфиг мне на проверку.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Let an AI agent set Tunlock up", "Настройка Tunlock через ИИ-агента")).font(.title3.weight(.semibold))
                    Text(L("Connect Tunlock to Claude Code, Claude Desktop or Cursor over MCP. The agent finds your TUN app, checks your server or proxy and fills the settings in for you.",
                           "Подключите Tunlock к Claude Code, Claude Desktop или Cursor по MCP. Агент найдёт ваше TUN-приложение, проверит сервер или прокси и заполнит настройки."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                list(L("The agent can", "Агент может"), "checkmark.circle.fill", .green, [
                    L("see the status and the current exit", "видеть статус и текущий выход"),
                    L("find TUN apps, VPNs and your network", "находить TUN-приложения, VPN и вашу сеть"),
                    L("check SSH, the proxy and the exit", "проверять SSH, прокси и выход"),
                    L("propose settings for you to review", "предлагать настройки вам на проверку"),
                ])
                list(L("The agent cannot", "Агент не может"), "xmark.circle.fill", .red, [
                    L("apply settings or turn Tunlock off", "применять настройки и выключать Tunlock"),
                    L("uninstall or change the firewall", "удалять Tunlock и менять файрвол"),
                    L("see passwords or SSH keys", "видеть пароли и SSH-ключи"),
                ])
            }

            if !inApplications {
                Label(L("Move Tunlock to /Applications first, so this path stays valid.",
                        "Сначала перенесите Tunlock в /Applications, чтобы этот путь не сломался."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }

            snippet("Claude Code", claudeCode)
            snippet(L("Claude Desktop, Cursor (JSON)", "Claude Desktop, Cursor (JSON)"), jsonConfig)
            snippet(L("Then ask the agent", "Затем попросите агента"), prompt)
        }
        .padding(20)
        .frame(width: 560)
    }

    private func list(_ title: String, _ icon: String, _ color: Color, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold))
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: icon).font(.callout).foregroundStyle(.primary)
                    .labelStyle(TintedIcon(color: color))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                Button(copied == title ? L("Copied", "Скопировано") : L("Copy", "Скопировать")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = title
                }
            }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
    }
}

private struct TintedIcon: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(color)
            configuration.title
        }
    }
}
