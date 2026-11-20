import AppKit
import Foundation
import SwiftUI

enum Verdict {
    case notSetUp, notRunning, protected, blocked, direct, unprotected, switchFailed

    var symbol: String {
        switch self {
        case .protected: return "lock.shield.fill"
        case .blocked: return "exclamationmark.shield.fill"
        case .direct: return "shield.slash"
        case .notSetUp: return "shield"
        case .notRunning, .unprotected, .switchFailed: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .protected: return .green
        case .blocked: return .orange
        case .direct: return .secondary
        case .notSetUp: return .secondary
        case .notRunning, .unprotected, .switchFailed: return .red
        }
    }

    var title: String {
        switch self {
        case .protected: return L("Protected", "Защищено")
        case .blocked: return L("Internet blocked", "Интернет заблокирован")
        case .direct: return L("Off", "Выключено")
        case .notSetUp: return L("Not set up", "Не настроено")
        case .notRunning: return L("Service not running", "Служба не работает")
        case .unprotected: return L("Protection failed", "Защита не действует")
        case .switchFailed: return L("Switch failed", "Сбой переключения")
        }
    }

    var explanation: String {
        switch self {
        case .protected:
            return L("All traffic leaves through your server, and its IP is verified.",
                     "Весь трафик идёт через ваш сервер, его IP проверен.")
        case .blocked:
            return L("No verified tunnel, so nothing leaves the Mac. Turn on your TUN app or wait for reconnection.",
                     "Проверенного туннеля нет, поэтому ничего не выходит наружу. Включите TUN-приложение или дождитесь переподключения.")
        case .direct:
            return L("Tunlock blocks nothing. Its SSH tunnel and the TUN app are stopped; traffic goes as usual.",
                     "Tunlock ничего не блокирует. Его SSH-туннель и TUN-приложение остановлены, трафик идёт как обычно.")
        case .notSetUp:
            return L("Enter your server once, and Tunlock does the rest.",
                     "Один раз укажите сервер, остальное Tunlock сделает сам.")
        case .notRunning:
            return L("The background guard does not answer. Open Settings and press Save and apply.",
                     "Фоновая служба не отвечает. Откройте настройки и нажмите «Сохранить и применить».")
        case .unprotected:
            return L("Protected mode is on, but Tunlock's firewall rules are not the ones deciding.",
                     "Защищённый режим включён, но решают не правила Tunlock.")
        case .switchFailed:
            return L("Direct mode was asked, but the firewall rules could not be removed: the internet may still be blocked.",
                     "Запрошен прямой режим, но правила файрвола снять не удалось: интернет может оставаться заблокированным.")
        }
    }
}

@MainActor
final class StatusModel: ObservableObject {
    static let shared = StatusModel()

    @Published private(set) var state: [String: String] = [:]
    @Published private(set) var installed = false
    @Published private(set) var stale = true
    @Published private(set) var rate: (down: Double, up: Double)?
    @Published private(set) var totalDown: Double = 0
    @Published private(set) var totalUp: Double = 0
    /// Public IP and country seen in direct mode (the guard only probes the tunnel).
    @Published private(set) var directIP: String?
    @Published private(set) var directCountry: String?
    private var directCheckedAt = Date.distantPast
    @Published private(set) var rateInterface: String?
    @Published var busy: String?
    @Published var message: String?
    @Published var testOutput: String?

    private var meter = RateMeter()
    private var timer: Timer?
    // Notifications fire only for a state that held for a few seconds.
    private var shownVerdict: Verdict?
    private var pendingVerdict: Verdict?
    private var pendingSince = Date()

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in StatusModel.shared.refresh() }
        }
    }

    func refresh() {
        installed = FileManager.default.fileExists(atPath: Paths.daemon)
            && FileManager.default.fileExists(atPath: Paths.config)
        var s: [String: String] = [:]
        if let text = try? String(contentsOfFile: Paths.state, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let eq = line.firstIndex(of: "=") { s[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
            }
        }
        state = s
        let updated = TimeInterval(s["updated"] ?? "") ?? 0
        stale = Date().timeIntervalSince1970 - updated > 10
        // Tunnel traffic when there is a tunnel, otherwise the main connection.
        let iface = (s["tun"].flatMap { $0.isEmpty ? nil : $0 }) ?? primaryInterface()
        if iface != rateInterface { totalDown = 0; totalUp = 0 }
        rateInterface = iface
        if let r = meter.sample(iface) {
            rate = (r.down, r.up)
            totalDown += r.dDown
            totalUp += r.dUp
        } else {
            rate = nil
        }
        checkDirectIP()
        trackVerdict()
    }

    private func checkDirectIP() {
        guard verdict == .direct else { directIP = nil; directCountry = nil; return }
        guard Date().timeIntervalSince(directCheckedAt) > 60 else { return }
        directCheckedAt = Date()
        Task {
            let r = await run("/usr/bin/curl", ["-4fsS", "--max-time", "6", "https://1.1.1.1/cdn-cgi/trace"])
            var values: [String: String] = [:]
            for line in r.output.split(separator: "\n") {
                let p = line.split(separator: "=", maxSplits: 1).map(String.init)
                if p.count == 2 { values[p[0]] = p[1] }
            }
            directIP = values["ip"]
            directCountry = values["loc"]
        }
    }

    var verdict: Verdict {
        if !installed { return .notSetUp }
        if stale { return .notRunning }
        if state["mode"] == "direct" { return (state["error"] ?? "").isEmpty ? .direct : .switchFailed }
        let rules = Int(state["pf_rules"] ?? "") ?? 0
        if state["pf_enabled"] == "1", state["pf_reachable"] == "1", rules > 0, (state["error"] ?? "").isEmpty,
           (state["pf_conflict"] ?? "").isEmpty {
            return state["phase"] == "open" ? .protected : .blocked
        }
        return .unprotected
    }

    var mode: String { state["mode"] ?? "direct" }

    var installedVersion: String? { backendVersion(atPath: Paths.cli) }
    var bundledVersion: String? { backendVersion(atPath: Paths.bundledCLI) }
    var needsUpdate: Bool {
        guard installed, let a = installedVersion, let b = bundledVersion else { return false }
        return a != b
    }

    // MARK: actions

    func setMode(_ protected: Bool) {
        if protected, verdict == .notRunning {
            message = L("The background service is not running. Open Settings and press Save and apply.",
                        "Фоновая служба не запущена. Откройте настройки и нажмите «Сохранить и применить».")
            return
        }
        let cmd = protected ? "on" : "off"
        busy = protected ? L("Turning on: firewall, then SSH and the TUN app…", "Включаю: сначала файрвол, потом SSH и TUN-приложение…")
                         : L("Turning off…", "Выключаю…")
        message = nil
        Task {
            let r = await runCLIAsRoot(cmd)
            busy = nil
            if !r.ok && !r.cancelled {
                // The CLI ends with the reason; the panel shows the details already.
                message = r.output.split(separator: "\n").last { $0.hasPrefix("tunlock:") }.map(String.init)
                    ?? r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            directCheckedAt = .distantPast
            refresh()
        }
    }

    func runLeakTest() {
        busy = L("Testing for leaks…", "Проверяю утечки…")
        Task {
            let r = await runCLIAsRoot("test")
            busy = nil
            if r.cancelled { return }
            testOutput = r.output
            Windows.shared.showLeakTest()
        }
    }

    /// Writes the config as root and (re)installs the bundled backend.
    func apply(_ config: TunConfig, passwordless: Bool) async -> String? {
        if let error = await config.validate() { return error }
        let tmp = NSTemporaryDirectory() + "tunlock-\(UUID().uuidString).conf"
        do { try config.render().write(toFile: tmp, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        var cmd = "mkdir -p /usr/local/etc && install -o root -g wheel -m 644 \(shellQuote(tmp)) /usr/local/etc/tunlock.conf"
        cmd += " && /bin/bash \(shellQuote(Paths.bundled + "/install.sh")) --user \(shellQuote(NSUserName()))"
        if passwordless { cmd += " --sudoers" }
        let r = await runAsAdmin(cmd)
        refresh()
        if r.cancelled { return L("Cancelled.", "Отменено.") }
        return r.ok ? nil : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trackVerdict() {
        let v = verdict
        if v != pendingVerdict {
            pendingVerdict = v
            pendingSince = Date()
            return
        }
        guard v != shownVerdict, Date().timeIntervalSince(pendingSince) >= 4 else { return }
        defer { shownVerdict = v }
        guard let from = shownVerdict, busy == nil else { return }  // not at launch, not for our own switching
        let s = state
        let exit = [s["egress_ip"] ?? "", s["egress_country"].map { "\(flagEmoji($0)) \(countryName($0))" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        switch v {
        case .protected where from != .direct && from != .notSetUp:
            Notifier.post(L("Protected again", "Снова защищено"), L("Exit ", "Выход ") + exit)
        case .blocked where from == .protected:
            Notifier.post(L("Internet closed", "Интернет закрыт"), closeReason())
        case .unprotected:
            Notifier.post(L("Protection is not in force", "Защита не действует"),
                          s["pf_conflict"].flatMap { $0.isEmpty ? nil : $0 } ?? s["error"] ?? "")
        case .notRunning where from == .protected || from == .blocked:
            Notifier.post(L("Tunlock service not responding", "Служба Tunlock не отвечает"),
                          L("Open Tunlock to see what happened.", "Откройте Tunlock, чтобы посмотреть, что случилось."))
        default:
            break
        }
    }

    /// Why the guard closed the internet, in one line.
    func closeReason() -> String {
        let s = state
        if let ip = s["egress_ip"], !ip.isEmpty, exitIsForeign {
            return L("The exit changed to ", "Выход сменился на ") + ip + " " + flagEmoji(s["egress_country"] ?? "")
        }
        if s["upstream"] != "proxy", s["ssh"] == "down" { return L("SSH dropped. Waiting for it to reconnect.", "SSH отвалился. Жду переподключения.") }
        if (s["tun"] ?? "").isEmpty { return L("The TUN app is off.", "TUN-приложение выключено.") }
        return L("The exit did not answer. Waiting for a verified tunnel.", "Выход не ответил. Жду подтверждённый туннель.")
    }

    /// The last probe answered, but not with our exit.
    var exitIsForeign: Bool {
        let s = state
        guard s["egress_ok"] != "1", let ip = s["egress_ip"], !ip.isEmpty else { return false }
        let expected = s["expected"] ?? "", cc = s["expected_country"] ?? ""
        return (expected != "any" && ip != expected) || (!cc.isEmpty && s["egress_country"] != cc)
    }

    /// Pin exactly the exit the user confirmed (not whatever the state says by
    /// the time they click). The current mode is kept: IP, country or both.
    func pinExit(ip: String, country cc: String) {
        guard var config = TunConfig.loadInstalled(), !ip.isEmpty else { return }
        if config.exitMode != .ip, cc.count != 2 {
            message = L("The exit's country is unknown: check again before pinning.",
                        "Страна выхода не определилась: проверьте ещё раз, прежде чем закреплять.")
            return
        }
        switch config.exitMode {
        case .ip: config.expectedEgress = ip
        case .country: config.expectedCountry = cc
        case .both: config.expectedEgress = ip; config.expectedCountry = cc
        }
        busy = L("Pinning the new exit…", "Закрепляю новый выход…")
        Task {
            let error = await apply(config, passwordless: FileManager.default.fileExists(atPath: Paths.sudoers))
            busy = nil
            message = error
            refresh()
        }
    }

    func uninstall() {
        busy = L("Removing…", "Удаляю…")
        Task {
            let r = await runAsAdmin("/bin/bash " + shellQuote(Paths.bundled + "/uninstall.sh") + " --purge --user " + shellQuote(NSUserName()))
            busy = nil
            if !r.ok && !r.cancelled { message = r.output }
            refresh()
        }
    }
}
