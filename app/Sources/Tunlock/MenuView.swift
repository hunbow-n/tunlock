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

    var body: some View {
        let v = model.verdict
        VStack(alignment: .leading, spacing: 12) {
            header(v)
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
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
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
                    Text(v.explanation).font(.callout).foregroundStyle(.secondary)
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
                Text(on ? L("Internet only through your server", "Интернет только через ваш сервер")
                        : L("Nothing blocked, tunnel stopped", "Ничего не блокирует, туннель остановлен"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { model.setMode($0) }))
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                .disabled(model.busy != nil)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill((on ? Color.green : Color.primary).opacity(on ? 0.12 : 0.05)))
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
                    detail: L("no tunnel, no kill switch", "без туннеля и без защиты"), last: true)
            } else {
                if s["cascade"] == "1" {
                    let up = s["entry_up"]
                    Hop(status: up == "up" ? .good : up == "down" ? .bad : .neutral,
                        title: L("Entry", "Вход") + (entryName.isEmpty ? "" : " · \(entryName)"),
                        detail: (s["entry"] ?? "") + " · " + (up == "up" ? L("reachable", "доступен")
                            : up == "down" ? L("not reachable", "недоступен") : L("checking", "проверяю")))
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

    private func exitStatus(_ s: [String: String]) -> Hop.Status {
        if s["egress_ok"] == "1" { return .good }
        if s["ssh"] != "up" { return .bad }
        return .warn
    }

    private func exitDetail(_ s: [String: String]) -> String {
        let expected = s["expected"] ?? ""
        var parts = [expected]
        if let c = s["egress_country"], !c.isEmpty { parts.append("\(flagEmoji(c)) \(countryName(c))") }
        if s["ssh"] != "up" {
            parts.append(L("SSH down", "SSH не подключён"))
        } else if s["egress_ok"] == "1" {
            let age = Int(Date().timeIntervalSince1970 - (TimeInterval(s["egress_at"] ?? "") ?? 0))
            parts.append(age < 120 ? L("verified \(age)s ago", "проверен \(age) с назад")
                                   : L("verified \(age / 60)m ago", "проверен \(age / 60) мин назад"))
        } else if let ip = s["egress_ip"], !ip.isEmpty, ip != expected {
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
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var footer: some View {
        HStack {
            Button(L("Settings…", "Настройки…")) { Windows.shared.showSettings() }
            if model.verdict != .notSetUp {
                Button(L("Leak test", "Тест утечек")) { model.runLeakTest() }
                    .disabled(model.busy != nil)
            }
            Spacer()
            Button(L("Quit", "Выйти")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .help(L("Protection keeps working without the app", "Защита продолжит работать без приложения"))
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
