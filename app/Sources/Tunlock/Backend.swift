import Foundation

/// Where the installed backend lives (see install.sh) and what ships inside the app.
enum Paths {
    static let cli = "/usr/local/libexec/tunlock/tunlock"
    static let config = ProcessInfo.processInfo.environment["TUNLOCK_UI_CONFIG"] ?? "/usr/local/etc/tunlock.conf"
    // Overridable only for UI snapshots (tools/snapshot.swift).
    static let state = ProcessInfo.processInfo.environment["TUNLOCK_UI_STATE"] ?? "/var/run/tunlock/state"
    static let daemon = ProcessInfo.processInfo.environment["TUNLOCK_UI_DAEMON"] ?? "/Library/LaunchDaemons/tunlock.guard.plist"
    static let sudoers = "/etc/sudoers.d/tunlock"
    static let guardLog = "/var/log/tunlock.log"
    static var sshLog: String { NSHomeDirectory() + "/Library/Logs/tunlock-ssh.log" }
    static var bundled: String { (Bundle.main.resourcePath ?? "") + "/backend" }
    static var bundledCLI: String { bundled + "/bin/tunlock" }
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

    var effectiveEgress: String { expectedEgress.isEmpty ? vpsIP : expectedEgress }

    func render() -> String {
        var lines = [
            "# Written by Tunlock.app. See tunlock.conf.example for all options.",
            "VPS_IP=\(vpsIP)",
            "SSH_USER=\(sshUser)",
            "SSH_PORT=\(sshPort)",
            "SSH_FORWARD=\"\(forwardString)\"",
            "TUN_ADDR=\(tunAddr)",
            "TUN_MASK=\(tunMask)",
            "PROBE_INTERVAL=\(probeInterval)",
            "TUN_SERVICE=\"\(tunService)\"",
        ]
        if !identity.isEmpty { lines.append("SSH_IDENTITY=\(identity)") }
        if !bypassNets.isEmpty { lines.append("BYPASS_NETS=\"\(bypassNets.joined(separator: " "))\"") }
        let dns = bypassDNS.filter { !$0.domain.isEmpty && !$0.server.isEmpty }
        if !dns.isEmpty { lines.append("BYPASS_DNS=\"\(dns.map { "\($0.domain)=\($0.server)" }.joined(separator: " "))\"") }
        if cascade {
            lines.append("JUMP_HOST=\(jumpHost)")
            lines.append("JUMP_USER=\(jumpUser.isEmpty ? sshUser : jumpUser)")
            lines.append("JUMP_PORT=\(jumpPort)")
        }
        if !expectedEgress.isEmpty, expectedEgress != vpsIP { lines.append("EXPECTED_EGRESS=\(expectedEgress)") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String) -> TunConfig {
        var values: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            var value = String(line[line.index(after: eq)...])
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            values[String(line[..<eq])] = value
        }
        var c = TunConfig()
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
