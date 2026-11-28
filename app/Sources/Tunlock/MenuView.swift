import SwiftUI

/// User-facing names for the hops, set in Settings (display only).
enum HopNames {
    static let entryKey = "entryName"
    static let exitKey = "exitName"
}

struct MenuView: View {
    @EnvironmentObject var model: StatusModel
    @AppStorage(HopNames.entryKey) private var entryName = ""
    @AppStorage(HopNames.exitKey) private var exitName = ""

    /// Height of everything above the footer, measured as laid out.
    @State private var bodyHeight: CGFloat = 0
    /// The footer, its divider and the panel's own padding.
    private let footerRoom: CGFloat = 44 + Shape.panelPadding * 2 + Shape.footerInset

    var body: some View {
        let limit = panelMaxHeight() - footerRoom
        VStack(alignment: .leading, spacing: 12) {
            // Taller than the screen allows: the middle scrolls, the footer stays.
            if bodyHeight > limit {
                ScrollView(.vertical) { content }.frame(height: limit)
            } else {
                content
            }
            Divider()
            footer
        }
        .padding(Shape.panelPadding)
        // The footer sits in the panel's rounded corners: give it room so the
        // corner curve never clips "Settings…" or "Quit".
        .padding(.bottom, Shape.footerInset)
        .frame(width: 340)
        .background(PanelChrome())
    }

    private var content: some View {
        let v = model.verdict
        return VStack(alignment: .leading, spacing: 12) {
            header(v)
            if model.mode == "protected", model.exitIsForeign { foreignExitCard }
            if v == .notSetUp {
                Button {
                    Windows.shared.showSettings()
                } label: {
                    Text(L("Set up…", "Настроить…")).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            } else {
                modeSwitch
                if let prompt = model.offPrompt { offConfirmation(prompt) }
                if !model.aiClients.isEmpty { aiClientsLine }
                if model.keepingAwake {
                    Label(L("Mac stays awake while they run", "Mac не уснёт, пока они запущены"), systemImage: "cup.and.saucer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                card { route(v) }
                card { traffic }
                extras(v)
            }
            if let busy = model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let warning = model.state["warning"], !warning.isEmpty {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let conflict = model.state["pf_conflict"], !conflict.isEmpty, v != .direct {
                Label(L("Other firewall rules decide before Tunlock: ", "Раньше Tunlock решают другие правила файрвола: ") + conflict,
                      systemImage: "exclamationmark.octagon").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.state["error"], !error.isEmpty, v != .direct {
                Label(error, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear.preference(key: BodyHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(BodyHeightKey.self) { bodyHeight = $0 }
    }

    @State private var confirmPin = false
    /// The exit shown in the confirmation; pinned as is, even if a newer probe arrives.
    @State private var pinTarget: (ip: String, country: String) = ("", "")

    /// The exit answered from somewhere else: say so, and offer one way out.
    private var foreignExitCard: some View {
        let s = model.state
        let ip = s["egress_ip"] ?? ""
        let cc = s["egress_country"] ?? ""
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ip) \(flagEmoji(cc)) \(countryName(cc))").font(.callout.weight(.medium)).textSelection(.enabled)
                Text(L("Your server or proxy now? Pin it. If not, leave it closed.",
                       "Это ваш новый сервер или прокси? Закрепите. Если нет — оставьте закрытым."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(L("Pin…", "Закрепить…")) { pinTarget = (ip, cc); confirmPin = true }
                .disabled(model.busy != nil)
                .confirmationDialog(L("Make \(pinTarget.ip) \(flagEmoji(pinTarget.country)) your exit?",
                                      "Сделать \(pinTarget.ip) \(flagEmoji(pinTarget.country)) своим выходом?"),
                                    isPresented: $confirmPin) {
                    Button(L("Pin \(pinTarget.ip)", "Закрепить \(pinTarget.ip)")) {
                        model.pinExit(ip: pinTarget.ip, country: pinTarget.country)
                    }
                } message: {
                    Text(L("Only if you changed the server or proxy yourself. If not, someone else's exit is in the way: keep the internet closed.",
                           "Только если вы сами сменили сервер или прокси. Если нет, на пути чужой выход: оставьте интернет закрытым."))
                }
        }
        .padding(Shape.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Shape.card().fill(Color.orange.opacity(0.12)))
    }

    // MARK: header

    private func header(_ v: Verdict) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: v.symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(v.color)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.title).font(.title3.weight(.semibold))
                if let ip = currentIP(v) {
                    HStack(spacing: 6) {
                        Text(ip.ip).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        if let c = ip.country {
                            Text("\(flagEmoji(c)) \(countryName(c))").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text((v == .blocked || v == .unprotected) && model.mode == "protected" ? model.closeReason() : v.explanation)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The address the internet sees right now, when it is known.
    private func currentIP(_ v: Verdict) -> (ip: String, country: String?)? {
        switch v {
        case .protected:
            guard let ip = model.state["egress_ip"], !ip.isEmpty else { return nil }
            let c = model.state["egress_country"] ?? ""
            return (ip, c.isEmpty ? nil : c)
        case .direct:
            guard let ip = model.directIP else { return nil }
            return (ip, model.directCountry)
        default:
            return nil
        }
    }

    /// One switch: on = protected (rules first, then SSH and the TUN client),
    /// off = Tunlock blocks nothing and holds nothing. Off always works.
    private var modeSwitch: some View {
        let on = model.mode == "protected"
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(on ? L("Tunlock is on", "Tunlock включён") : L("Tunlock is off", "Tunlock выключен"))
                    .font(.headline)
                Text(on ? L("Internet only through the verified exit", "Интернет только через проверенный выход")
                        : L("Nothing blocked, tunnel stopped", "Ничего не блокирует, туннель остановлен"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { model.setMode($0) }))
                .toggleStyle(PowerSwitchStyle(busy: model.busy != nil))
                .labelsHidden()
                .disabled(model.busy != nil || model.offPrompt != nil)
        }
        .padding(Shape.cardPadding)
        .background(Shape.card().fill((on ? Color.green : Color.primary).opacity(on ? 0.12 : 0.05)))
    }

    /// Keep the confirmation inside the status panel so it can receive clicks.
    private func offConfirmation(_ prompt: OffPrompt) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text(prompt == .checkFailed ? L("Could not check AI apps", "Не удалось проверить AI-приложения")
                     : L("AI apps are still running", "AI-приложения ещё запущены"))
                    .font(.headline)
                Text(prompt.message(claudeClosed: !(model.state["ai_nets"] ?? "").isEmpty))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.cancelOff()
                } label: {
                    Text(L("Keep on", "Оставить включённым")).frame(maxWidth: .infinity)
                }
                Button(role: .destructive) {
                    model.turnOffAnyway()
                } label: {
                    Text(L("Turn off anyway", "Всё равно выключить")).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    /// Which AI apps are running and what happens to their traffic now: from
    /// the verdict, not the chosen mode (protected mode can be blocked or broken).
    private var aiClientsLine: some View {
        let names = model.aiClients.joined(separator: ", ")
        let (text, icon, color): (String, String, Color)
        switch model.verdict {
        case .protected:
            (text, icon, color) = (L("Running, through Tunlock: \(names)", "Запущены, идут через Tunlock: \(names)"), "sparkles", .secondary)
        case .blocked:
            (text, icon, color) = (L("Running, blocked for now: \(names)", "Запущены, пока заблокированы: \(names)"), "exclamationmark.shield", .orange)
        case .direct where model.state["ai_closed"] == "1" && model.aiClients.allSatisfy({ $0.hasPrefix("Claude") }):
            (text, icon, color) = (L("Running, closed until Tunlock is on: \(names)", "Запущены, закрыты до включения Tunlock: \(names)"), "lock", .secondary)
        case .direct:
            (text, icon, color) = (L("Running, going direct: \(names)", "Запущены, идут напрямую: \(names)"), "exclamationmark.triangle", .orange)
        default:
            (text, icon, color) = (L("Running, may go direct: \(names)", "Запущены, могут идти напрямую: \(names)"), "exclamationmark.triangle", .red)
        }
        return Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: route

    @ViewBuilder
    private func route(_ v: Verdict) -> some View {
        let s = model.state
        let phys = s["phys"].flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 0) {
            Hop(status: phys == nil ? .bad : .good,
                title: L("This Mac", "Этот Mac"),
                detail: phys.map { "Wi‑Fi / Ethernet · \($0)" } ?? L("no network", "нет сети"))
            if v == .direct {
                Hop(status: .neutral, title: L("Internet, directly", "Интернет напрямую"),
                    detail: s["ai_closed"] == "1"
                        ? L("no tunnel; Claude is closed until Tunlock is on", "без туннеля; Claude закрыт, пока Tunlock выключен")
                        : L("no tunnel, no kill switch", "без туннеля и без защиты"), last: true)
            } else {
                if s["upstream"] == "proxy" {
                    let up = s["entry_up"]
                    Hop(status: up == "up" ? .good : up == "down" ? .bad : .neutral,
                        title: L("Proxy", "Прокси") + (entryName.isEmpty ? "" : " · \(entryName)"),
                        detail: (s["entry"] ?? "") + " · " + entryCheck(up))
                } else if s["cascade"] == "1" {
                    let up = s["entry_up"]
                    Hop(status: up == "up" ? .good : up == "down" ? .bad : .neutral,
                        title: L("Entry", "Вход") + (entryName.isEmpty ? "" : " · \(entryName)"),
                        detail: (s["entry"] ?? "") + " · " + entryCheck(up))
                }
                Hop(status: exitStatus(s), title: L("Exit", "Выход") + (exitName.isEmpty ? "" : " · \(exitName)"),
                    detail: exitDetail(s))
                Hop(status: v == .protected ? .good : .warn,
                    title: L("Internet", "Интернет"),
                    detail: v == .protected ? L("only through the exit", "только через выход")
                        : L("closed until the exit is verified", "закрыт, пока выход не проверен"),
                    last: true)
            }
        }
    }

    /// The entry check only opens a TCP connection; the exit is checked separately.
    private func entryCheck(_ up: String?) -> String {
        up == "up" ? L("TCP port open", "TCP-порт доступен")
            : up == "down" ? L("TCP port closed", "TCP-порт недоступен") : L("checking the TCP port", "проверяю TCP-порт")
    }

    private func exitStatus(_ s: [String: String]) -> Hop.Status {
        if s["egress_ok"] == "1" { return .good }
        if s["upstream"] != "proxy", s["ssh"] != "up" { return .bad }
        return .warn
    }

    private func exitDetail(_ s: [String: String]) -> String {
        let expected = s["expected"] ?? ""
        if model.exitIsForeign {
            let cc = s["expected_country"] ?? ""
            let want = expected == "any" ? L("any IP", "любой IP") : expected
            return L("expected ", "ожидается ") + want + (cc.isEmpty ? "" : " \(flagEmoji(cc))")
                + L(" · seen ", " · виден ") + (s["egress_ip"] ?? "") + " " + flagEmoji(s["egress_country"] ?? "")
        }
        var parts = [expected]
        if let c = s["egress_country"], !c.isEmpty { parts.append("\(flagEmoji(c)) \(countryName(c))") }
        if s["upstream"] != "proxy", s["ssh"] != "up" {
            parts.append(L("SSH down", "SSH не подключён"))
        } else if s["egress_ok"] == "1" {
            let age = Int(Date().timeIntervalSince1970 - (TimeInterval(s["egress_at"] ?? "") ?? 0))
            parts.append(age < 120 ? L("verified \(age)s ago", "проверен \(age) с назад")
                                   : L("verified \(age / 60)m ago", "проверен \(age / 60) мин назад"))
        } else if s["egress_check"] == "no_answer" {
            parts.append(L("no answer through the tunnel", "нет ответа через туннель"))
        } else if s["egress_check"] == nil, let ip = s["egress_ip"], !ip.isEmpty, ip != expected {
            parts.append(L("seen \(ip): wrong exit", "виден \(ip): чужой выход"))
        } else {
            parts.append(L("verifying…", "проверяю…"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: traffic

    private var traffic: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Label(model.rate.map { formatRate($0.down) } ?? "—", systemImage: "arrow.down")
                Label(model.rate.map { formatRate($0.up) } ?? "—", systemImage: "arrow.up")
                Spacer()
                Text(model.rateInterface ?? "").font(.caption).foregroundStyle(.tertiary)
            }
            .font(.system(.body, design: .rounded).weight(.medium))
            .monospacedDigit()
            Text(L("This session: ↓ \(formatBytes(model.totalDown))  ↑ \(formatBytes(model.totalUp))",
                   "За сессию: ↓ \(formatBytes(model.totalDown))  ↑ \(formatBytes(model.totalUp))"))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    @ViewBuilder
    private func extras(_ v: Verdict) -> some View {
        let s = model.state
        VStack(alignment: .leading, spacing: 4) {
            if v != .direct {
                HStack(spacing: 6) {
                    Image(systemName: v == .protected || v == .blocked ? "checkmark.shield" : "xmark.shield")
                        .foregroundStyle(v == .protected || v == .blocked ? .green : .red)
                    Text(L("Firewall: ", "Файрвол: ") + firewall(s))
                }
            }
            if v == .protected, let cc = s["egress_country"], cc.count == 2 {
                let tz = macTimeZone()
                if !tz.country.isEmpty, tz.country != cc {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                        Text(L("Mac time zone \(tz.zone) (\(flagEmoji(tz.country))) ≠ exit \(flagEmoji(cc)): sites can see it.",
                               "Часовой пояс Mac \(tz.zone) (\(flagEmoji(tz.country))) ≠ выход \(flagEmoji(cc)): сайты это видят."))
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("Change…", "Изменить…")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension")!)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            if let bypass = s["bypass"], !bypass.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.right").foregroundStyle(.secondary)
                    Text(L("Directly: ", "Напрямую: ") + bypass.replacingOccurrences(of: " ", with: ", "))
                        .textSelection(.enabled)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func firewall(_ s: [String: String]) -> String {
        switch s["phase"] {
        case "open": return L("only via ", "только через ") + (s["tun"] ?? "tunnel")
        case "probe": return L("checking the exit", "проверяю выход")
        case "block": return L("everything blocked", "всё заблокировано")
        case "emergency": return L("emergency block: pf rejected the normal rules", "аварийная блокировка: PF отклонил обычные правила")
        case "failed": return L("pf rejects all rules", "PF отклоняет все правила")
        default: return L("off", "выключен")
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(Shape.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Shape.card().fill(Color.primary.opacity(0.05)))
    }

    @State private var confirmQuit = false

    private var footer: some View {
        HStack {
            Button(L("Settings…", "Настройки…")) { Windows.shared.showSettings() }
            if model.verdict != .notSetUp {
                Button(L("Leak test", "Тест утечек")) { model.runLeakTest() }
                    .disabled(model.busy != nil)
            }
            Spacer()
            Button {
                Windows.shared.showAgent()
            } label: { Image(systemName: "sparkles") }
                .help(L("Let an AI agent set Tunlock up (MCP)", "Настроить Tunlock через ИИ-агента (MCP)"))
            Button(L("Quit", "Выйти")) { confirmQuit = true }
                .keyboardShortcut("q")
                .help(L("Protection keeps working without the app", "Защита продолжит работать без приложения"))
                .confirmationDialog(L("Quit the Tunlock app?", "Закрыть приложение Tunlock?"), isPresented: $confirmQuit) {
                    Button(L("Quit", "Выйти")) { NSApp.terminate(nil) }
                    Button(L("Cancel", "Отмена"), role: .cancel) {}
                } message: {
                    // The guard and the tunnel run under launchd: quitting closes only this window and its notifications.
                    Text(model.mode == "protected"
                         ? L("Protection stays on: the internet still goes only through the verified exit. You will not see the status or get notifications until you open Tunlock again.",
                             "Защита останется включённой: интернет по-прежнему идёт только через проверенный выход. Статус и уведомления будут недоступны, пока вы снова не откроете Tunlock.")
                         : L("Tunlock stays off and blocks nothing. You will not see the status or get notifications until you open Tunlock again.",
                             "Tunlock останется выключенным и ничего не блокирует. Статус и уведомления будут недоступны, пока вы снова не откроете Tunlock."))
                }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

/// One step of the route: a status dot on a vertical line, a title and a detail.
struct Hop: View {
    enum Status { case good, warn, bad, neutral }
    let status: Status
    let title: String
    let detail: String
    var last = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(color).frame(width: 10, height: 10).padding(.top, 4)
                if !last {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, last ? 0 : 8)
        }
    }

    private var color: Color {
        switch status {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        case .neutral: return .secondary
        }
    }
}

private struct BodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
