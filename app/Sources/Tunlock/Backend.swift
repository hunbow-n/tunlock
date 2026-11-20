import Foundation

/// Where the installed backend lives (see install.sh) and what ships inside the app.
enum Paths {
    static let cli = "/usr/local/libexec/tunlock/tunlock"
    static let config = ProcessInfo.processInfo.environment["TUNLOCK_UI_CONFIG"] ?? "/usr/local/etc/tunlock.conf"
    // Overridable only for UI snapshots (tools/snapshot.swift).
    static let state = ProcessInfo.processInfo.environment["TUNLOCK_UI_STATE"] ?? "/var/run/tunlock/state"
    static let daemon = ProcessInfo.processInfo.environment["TUNLOCK_UI_DAEMON"] ?? "/Library/LaunchDaemons/tunlock.guard.plist"
    static let sudoers = "/etc/sudoers.d/tunlock"
    static let guardLog = ProcessInfo.processInfo.environment["TUNLOCK_UI_LOG"] ?? "/var/log/tunlock.log"
    static var sshLog: String { NSHomeDirectory() + "/Library/Logs/tunlock-ssh.log" }
    static var bundled: String { (Bundle.main.resourcePath ?? "") + "/backend" }
    static var bundledCLI: String { bundled + "/bin/tunlock" }
    /// Where an AI agent's proposed config waits for the user (see MCP.swift).
    static var draftDir: String { NSHomeDirectory() + "/Library/Application Support/Tunlock" }
    static var draft: String { ProcessInfo.processInfo.environment["TUNLOCK_UI_DRAFT"] ?? draftDir + "/draft.conf" }
}

struct RunResult {
    var status: Int32
    var output: String
    var ok: Bool { status == 0 }
    var cancelled: Bool { output.contains("(-128)") }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func run(_ path: String, _ args: [String], env: [String: String]? = nil) async -> RunResult {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            if let env { p.environment = env }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch {
                cont.resume(returning: RunResult(status: -1, output: error.localizedDescription))
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            cont.resume(returning: RunResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self)))
        }
    }
}

/// Runs a shell command as root behind the standard macOS administrator prompt.
func runAsAdmin(_ command: String) async -> RunResult {
    let escaped = (command + " 2>&1")
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return await run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
}

/// Runs an installed CLI command as root: without a password when the sudoers
/// entry allows it, otherwise through the administrator prompt.
func runCLIAsRoot(_ subcommand: String) async -> RunResult {
    if FileManager.default.fileExists(atPath: Paths.sudoers) {
        let r = await run("/usr/bin/sudo", ["-n", Paths.cli, subcommand])
        if r.ok || !r.output.contains("password") { return r }
    }
    return await runAsAdmin(shellQuote(Paths.cli) + " " + subcommand)
}

func backendVersion(atPath path: String) -> String? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") where line.hasPrefix("VERSION=") {
        return String(line.dropFirst("VERSION=".count))
    }
    return nil
}

// MARK: - config

enum ForwardKind: String, CaseIterable, Identifiable {
    case shadowsocks, socks, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shadowsocks: return L("Proxy on the server (Outline, Shadowsocks…)", "Прокси на сервере (Outline, Shadowsocks…)")
        case .socks: return L("SSH only (SOCKS, nothing on the server)", "Только SSH (SOCKS, на сервере ничего не нужно)")
        case .custom: return L("Custom ssh -L / -D options", "Свои опции ssh -L / -D")
        }
    }
}

struct DNSRule: Equatable, Identifiable {
    var id = UUID()
    var domain: String
    var server: String
    static func == (a: DNSRule, b: DNSRule) -> Bool { a.domain == b.domain && a.server == b.server }
}

/// The subset of tunlock.conf the app edits. Unknown lines are not kept:
/// the file is fully owned by this form once saved from the app.
struct TunConfig: Equatable {
    /// "ssh": through an SSH forward to your server. "proxy": the TUN app
    /// connects straight to a proxy; Tunlock runs no SSH and never sees the
    /// proxy's login and password, which stay in the TUN app.
    var upstream = "ssh"
    var proxyHost = ""
    var proxyPort = ""
    var vpsIP = ""
    var sshUser = NSUserName()
    var sshPort = "22"
    var identity = ""
    var forward: ForwardKind = .shadowsocks
    var localPort = "10800"
    var remotePort = ""
    var customForward = ""
    var cascade = false
    var jumpHost = ""
    var jumpUser = ""
    var jumpPort = "22"
    var bypassNets: [String] = []
    var bypassDNS: [DNSRule] = []
    var tunAddr = ""
    var tunMask = ""
    var expectedEgress = ""
    var probeInterval = "30"
    var tunService = ""

    var forwardString: String {
        switch forward {
        case .shadowsocks: return "-L 127.0.0.1:\(localPort):127.0.0.1:\(remotePort)"
        case .socks: return "-D 127.0.0.1:\(localPort)"
        case .custom: return customForward
        }
    }

    var expectedCountry = ""
    /// Keys the form has no field for (SSH_HOST, PROBE_URL, PF_ANCHOR…), carried
    /// through unchanged so saving from the app never drops what the file says.
    var extras: [(key: String, value: String)] = []

    static let modeledKeys: Set<String> = [
        "UPSTREAM", "PROXY_HOST", "PROXY_PORT", "VPS_IP", "SSH_USER", "SSH_PORT", "SSH_IDENTITY", "SSH_FORWARD",
        "JUMP_HOST", "JUMP_USER", "JUMP_PORT", "BYPASS_NETS", "BYPASS_DNS", "TUN_ADDR", "TUN_MASK", "TUN_SERVICE",
        "EXPECTED_EGRESS", "EXPECTED_COUNTRY", "PROBE_INTERVAL",
    ]

    private var extraLines: [String] { extras.map { "\($0.key)=\"\($0.value)\"" } }

    static func == (a: TunConfig, b: TunConfig) -> Bool {
        a.render() == b.render()
    }

    var isProxy: Bool { upstream == "proxy" }
    /// The pinned exit IP (empty, or "any" when only the country counts).
    /// Pasted values often carry a space or a newline: never compare those.
    var effectiveEgress: String {
        let e = clean(expectedEgress)
        return e.isEmpty ? clean(isProxy ? proxyHost : vpsIP) : e
    }

    /// What counts as "our" exit.
    enum ExitMode: String, CaseIterable, Identifiable {
        case ip, country, both
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ip: return L("Exact IP", "Точный IP")
            case .country: return L("Country", "Страна")
            case .both: return L("IP and country", "IP и страна")
            }
        }
    }

    /// Stored, not derived from the fields: "IP and country" must stay chosen
    /// while the country is still being typed.
    var exitMode: ExitMode = .ip {
        didSet {
            switch exitMode {
            case .ip, .both: if expectedEgress == "any" { expectedEgress = "" }
            case .country: expectedEgress = "any"
            }
        }
    }

    /// Country written to the config: only when the mode uses it.
    private var countryToWrite: String { exitMode == .ip ? "" : expectedCountry.uppercased() }

    /// Would the guard accept this probe answer?
    func exitMatches(ip: String, country: String) -> Bool {
        let ipOK = exitMode == .country || clean(ip) == effectiveEgress
        let countryOK = exitMode == .ip || country.uppercased() == expectedCountry.uppercased()
        return ipOK && countryOK
    }

    var exitDescription: String {
        let c = expectedCountry.isEmpty ? "" : "\(flagEmoji(expectedCountry)) \(countryName(expectedCountry))"
        switch exitMode {
        case .ip: return effectiveEgress
        case .country: return L("any IP in ", "любой IP, страна ") + c
        case .both: return "\(effectiveEgress) · \(c)"
        }
    }

    func render() -> String {
        if isProxy { return renderProxy() }
        var lines = [
            "# Written by Tunlock.app. See tunlock.conf.example for all options.",
            "VPS_IP=\(clean(vpsIP))",
            "SSH_USER=\(clean(sshUser))",
            "SSH_PORT=\(clean(sshPort))",
            "SSH_FORWARD=\"\(forwardString)\"",
            "TUN_ADDR=\(clean(tunAddr))",
            "TUN_MASK=\(tunMask)",
            "PROBE_INTERVAL=\(probeInterval)",
            "TUN_SERVICE=\"\(tunService)\"",
        ]
        if !identity.isEmpty { lines.append("SSH_IDENTITY=\(identity)") }
        if !bypassNets.isEmpty { lines.append("BYPASS_NETS=\"\(bypassNets.joined(separator: " "))\"") }
        let dns = bypassDNS.filter { !$0.domain.isEmpty && !$0.server.isEmpty }
        if !dns.isEmpty { lines.append("BYPASS_DNS=\"\(dns.map { "\($0.domain)=\($0.server)" }.joined(separator: " "))\"") }
        if cascade {
            lines.append("JUMP_HOST=\(clean(jumpHost))")
            lines.append("JUMP_USER=\(jumpUser.isEmpty ? sshUser : jumpUser)")
            lines.append("JUMP_PORT=\(clean(jumpPort))")
        }
        if !expectedEgress.isEmpty, expectedEgress != vpsIP { lines.append("EXPECTED_EGRESS=\(clean(expectedEgress))") }
        if !countryToWrite.isEmpty { lines.append("EXPECTED_COUNTRY=\(countryToWrite)") }
        lines += extraLines
        return lines.joined(separator: "\n") + "\n"
    }

    private func renderProxy() -> String {
        var lines = [
            "# Written by Tunlock.app. See tunlock.conf.example for all options.",
            "# The proxy's login and password live only in the TUN app.",
            "UPSTREAM=proxy",
            "PROXY_HOST=\(clean(proxyHost))",
            "PROXY_PORT=\(clean(proxyPort))",
            "TUN_ADDR=\(clean(tunAddr))",
            "TUN_MASK=\(tunMask)",
            "PROBE_INTERVAL=\(probeInterval)",
            "TUN_SERVICE=\"\(tunService)\"",
        ]
        if !bypassNets.isEmpty { lines.append("BYPASS_NETS=\"\(bypassNets.joined(separator: " "))\"") }
        let dns = bypassDNS.filter { !$0.domain.isEmpty && !$0.server.isEmpty }
        if !dns.isEmpty { lines.append("BYPASS_DNS=\"\(dns.map { "\($0.domain)=\($0.server)" }.joined(separator: " "))\"") }
        if !expectedEgress.isEmpty, expectedEgress != proxyHost { lines.append("EXPECTED_EGRESS=\(clean(expectedEgress))") }
        if !countryToWrite.isEmpty { lines.append("EXPECTED_COUNTRY=\(countryToWrite)") }
        lines += extraLines
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String) -> TunConfig {
        var values: [String: String] = [:]
        var order: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            var value = String(line[line.index(after: eq)...])
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if values[key] == nil { order.append(key) }
            values[key] = value
        }
        var c = TunConfig()
        c.extras = order.filter { !modeledKeys.contains($0) }.map { ($0, values[$0] ?? "") }
        c.vpsIP = values["VPS_IP"] ?? ""
        c.sshUser = values["SSH_USER"] ?? c.sshUser
        c.sshPort = values["SSH_PORT"] ?? "22"
        c.identity = values["SSH_IDENTITY"] ?? ""
        c.tunAddr = values["TUN_ADDR"] ?? ""
        c.tunMask = values["TUN_MASK"] ?? ""
        c.expectedEgress = values["EXPECTED_EGRESS"] ?? ""
        c.probeInterval = values["PROBE_INTERVAL"] ?? "30"
        c.jumpHost = values["JUMP_HOST"] ?? ""
        c.cascade = !c.jumpHost.isEmpty
        c.jumpUser = values["JUMP_USER"] ?? ""
        c.jumpPort = values["JUMP_PORT"] ?? "22"
        c.tunService = values["TUN_SERVICE"] ?? ""
        c.upstream = values["UPSTREAM"] == "proxy" ? "proxy" : "ssh"
        c.proxyHost = values["PROXY_HOST"] ?? ""
        c.proxyPort = values["PROXY_PORT"] ?? ""
        c.expectedCountry = values["EXPECTED_COUNTRY"] ?? ""
        let pinnedAny = c.expectedEgress == "any"
        c.exitMode = pinnedAny ? .country : (c.expectedCountry.isEmpty ? .ip : .both)
        if pinnedAny { c.expectedEgress = "any" }
        c.bypassNets = (values["BYPASS_NETS"] ?? "").split(separator: " ").map(String.init)
        c.bypassDNS = (values["BYPASS_DNS"] ?? "").split(separator: " ").compactMap { item in
            let p = item.split(separator: "=", maxSplits: 1).map(String.init)
            return p.count == 2 ? DNSRule(domain: p[0], server: p[1]) : nil
        }
        let fwd = values["SSH_FORWARD"] ?? ""
        let parts = fwd.split(separator: " ").map(String.init)
        let spec = parts.count == 2 ? parts[1].split(separator: ":").map(String.init) : []
        if parts.count == 2, parts[0] == "-L", spec.count == 4, spec[0] == "127.0.0.1", spec[2] == "127.0.0.1" {
            c.forward = .shadowsocks; c.localPort = spec[1]; c.remotePort = spec[3]
        } else if parts.count == 2, parts[0] == "-D", spec.count <= 2, let port = spec.last {
            c.forward = .socks; c.localPort = port
        } else if !fwd.isEmpty {
            c.forward = .custom; c.customForward = fwd
        }
        return c
    }

    static func loadDraft() -> TunConfig? {
        guard let text = try? String(contentsOfFile: Paths.draft, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func loadInstalled() -> TunConfig? {
        guard let text = try? String(contentsOfFile: Paths.config, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Validates with the same parser the root guard uses; returns its error.
    func validate() async -> String? {
        let tmp = NSTemporaryDirectory() + "tunlock-check-\(UUID().uuidString).conf"
        do { try render().write(toFile: tmp, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let r = await run("/bin/bash", [Paths.bundledCLI, "render-rules", "block"], env: ["TUNLOCK_CONF": tmp])
        if r.ok { return nil }
        return r.output.replacingOccurrences(of: "tunlock: ", with: "").replacingOccurrences(of: tmp + ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// VPN services macOS knows (scutil --nc list), e.g. "Karing".
func vpnServices() -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
    p.arguments = ["--nc", "list"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return out.split(separator: "\n").compactMap { line in
        guard let a = line.firstIndex(of: "\""), let b = line[line.index(after: a)...].firstIndex(of: "\"") else { return nil }
        return String(line[line.index(after: a)..<b])
    }
}

/// Trims spaces and line breaks that come with pasted addresses.
func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

func looksLikeIPv4(_ s: String) -> Bool {
    let p = clean(s).split(separator: ".", omittingEmptySubsequences: false)
    return p.count == 4 && p.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
}

/// The one exit check for the app and for MCP. Only an address that sits on a
/// utun right now, and the request is bound to that interface by name: a Wi-Fi
/// address can never reveal the direct IP. Blocking; call off the main thread.
enum ExitProbe: Equatable {
    case notTun
    case noAnswer
    case seen(ip: String, country: String)
}

func probeExit(tunAddr: String) -> ExitProbe {
    guard let tun = tunInterfaces().first(where: { $0.address == clean(tunAddr) }) else { return .notTun }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-4fsS", "--noproxy", "*", "--interface", "if!\(tun.name)",
                   "--connect-timeout", "4", "--max-time", "6", "https://1.1.1.1/cdn-cgi/trace"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return .noAnswer }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    var ip = "", cc = ""
    for line in out.split(separator: "\n") {
        if line.hasPrefix("ip=") { ip = String(line.dropFirst(3)) }
        if line.hasPrefix("loc=") { cc = String(line.dropFirst(4)) }
    }
    return ip.isEmpty ? .noAnswer : .seen(ip: ip, country: cc)
}
