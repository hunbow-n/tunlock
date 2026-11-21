import Foundation

/// `Tunlock --mcp`: a local MCP server over stdio for AI agents (Claude Code,
/// Claude Desktop, Cursor…). It can look around and prepare a configuration,
/// but it cannot change protection: no apply, no on/off, no uninstall. A
/// proposed config becomes a draft that the user reviews in Tunlock's settings
/// and saves with an administrator password.
enum MCPServer {
    static let protocolVersion = "2025-06-18"

    static let instructions = """
    Tunlock is a fail-closed kill switch for macOS: the Mac reaches the internet only through a verified exit \
    (an SSH tunnel to the user's server, or a proxy used by a TUN app such as Karing). To help set it up:
    1. Call `detect` to see TUN interfaces, VPN services and the local network (no network requests).
    2. Ask the user what they have: their own server (IP, SSH user, maybe a relay) or a proxy (IP and port only; \
    never ask for the proxy's login or password, Tunlock does not need them).
    3. Use `check_ssh` or `check_proxy`, and `check_exit` on the TUN app's interface to learn the exit IP and country.
    4. Build a tunlock.conf, call `validate_config` until it passes, then `propose_config`.
    The user then reviews the draft in Tunlock and presses Save. You cannot apply it or switch protection yourself.
    """

    // MARK: loop

    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let reply = handle(msg) { send(reply) }
        }
        exit(0)
    }

    static func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    /// Returns a JSON-RPC response, or nil for notifications.
    static func handle(_ msg: [String: Any]) -> [String: Any]? {
        let id = msg["id"]
        let method = msg["method"] as? String ?? ""
        guard let id else { return nil }  // notifications (e.g. notifications/initialized)
        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func err(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }
        switch method {
        case "initialize":
            return ok([
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "tunlock", "version": backendVersion(atPath: Paths.bundledCLI) ?? "0"],
                "instructions": instructions,
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": tools])
        case "tools/call":
            let params = msg["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard let tool = handlers[name] else { return err(-32602, "unknown tool \(name)") }
            let (text, isError) = tool(args)
            return ok(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return err(-32601, "method not found: \(method)")
        }
    }

    // MARK: tools

    static func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }

    static let str: [String: Any] = ["type": "string"]

    static let tools: [[String: Any]] = [
        ["name": "status",
         "description": "Tunlock's current state: on/off, verdict (protected, blocked, off…), exit IP and country, SSH or proxy, firewall phase. Read-only.",
         "inputSchema": schema([:])],
        ["name": "detect",
         "description": "What is on this Mac, without any network request: utun interfaces with IPv4 (TUN apps), VPN service names, the local network, and the setup-relevant fields of the installed Tunlock config. Read-only.",
         "inputSchema": schema([:])],
        ["name": "check_ssh",
         "description": "Try an SSH login (BatchMode, strict host key) to the user's server, optionally through a relay. Uses the user's own keys; nothing is stored.",
         "inputSchema": schema(["host": str, "user": str, "port": str, "identity": str,
                                "jump_host": str, "jump_user": str, "jump_port": str], required: ["host", "user"])],
        ["name": "check_proxy",
         "description": "Check that a proxy answers on IP:port (TCP). Only IP and port: never ask for or pass the proxy's login or password.",
         "inputSchema": schema(["host": str, "port": str], required: ["host", "port"])],
        ["name": "check_exit",
         "description": "Through a current TUN interface only: the exit IP and country (1.1.1.1), what claude.ai, api.anthropic.com and chatgpt.com see, and the Mac's time zone (sites can read it; one far from the exit's country stands out).",
         "inputSchema": schema(["tun_addr": str], required: ["tun_addr"])],
        ["name": "validate_config",
         "description": "Validate a complete tunlock.conf (KEY=value lines) with the same parser the root guard uses. Returns the errors, or the effective settings and the firewall rules each phase would load. Changes nothing.",
         "inputSchema": schema(["config": str], required: ["config"])],
        ["name": "propose_config",
         "description": "Hand a validated tunlock.conf to the user: Tunlock opens its settings with these values and a 'draft from an AI agent' note. Nothing is applied until the user reviews it and presses Save (with an administrator password).",
         "inputSchema": schema(["config": str, "note": str], required: ["config"])],
    ]

    static let handlers: [String: ([String: Any]) -> (String, Bool)] = [
        "status": { _ in status() },
        "detect": { _ in detect() },
        "check_ssh": checkSSH,
        "check_proxy": checkProxy,
        "check_exit": { args in checkExit(args["tun_addr"] as? String ?? "") },
        "validate_config": { args in
            let r = validate(args["config"] as? String ?? "") ?? "could not validate"
            return (r, !r.hasPrefix("VALID"))
        },
        "propose_config": propose,
    ]

    // MARK: implementations

    static func status() -> (String, Bool) {
        let cli = FileManager.default.isExecutableFile(atPath: Paths.cli) ? Paths.cli : nil
        guard let cli else { return ("Tunlock's background service is not installed yet. Use detect, then propose_config.", false) }
        let r = runSync("/bin/bash", [cli, "status", "--porcelain"])
        return (r.output.isEmpty ? "no state from the guard" : r.output, false)
    }

    /// Local discovery only: no request leaves the Mac, and of the installed
    /// config only the fields a setup needs (no comments, no key paths).
    static func detect() -> (String, Bool) {
        var out: [String: Any] = [:]
        out["tun_interfaces"] = tunInterfaces().map { ["name": $0.name, "address": $0.address, "mask": $0.mask, "prefix": $0.prefix] }
        out["vpn_services"] = vpnServices()
        out["local_network"] = currentLocalNetwork() ?? ""
        out["tunlock_installed"] = FileManager.default.fileExists(atPath: Paths.daemon)
        if let c = TunConfig.loadInstalled() { out["installed_settings"] = settingsSummary(c) }
        out["hint"] = "A TUN app in TUN mode shows up as a utun interface with an IPv4 address. Call check_exit with its address to see the exit IP and country (that sends one request through the tunnel)."
        return (json(out), false)
    }

    /// The installed config as an allowlist of fields.
    static func settingsSummary(_ c: TunConfig) -> [String: Any] {
        var d: [String: Any] = [
            "upstream": c.upstream, "tun_addr": c.tunAddr, "tun_mask": c.tunMask, "tun_service": c.tunService,
            "exit_mode": c.exitMode.rawValue, "expected_egress": c.expectedEgress, "expected_country": c.expectedCountry,
            "bypass_nets": c.bypassNets, "bypass_dns": c.bypassDNS.map { "\($0.domain)=\($0.server)" },
        ]
        if c.isProxy {
            d["proxy_host"] = c.proxyHost; d["proxy_port"] = c.proxyPort
        } else {
            d["vps_ip"] = c.vpsIP; d["ssh_user"] = c.sshUser; d["ssh_port"] = c.sshPort
            d["ssh_forward"] = c.forwardString; d["uses_ssh_key_file"] = !c.identity.isEmpty
            if c.cascade { d["jump_host"] = c.jumpHost; d["jump_user"] = c.jumpUser; d["jump_port"] = c.jumpPort }
        }
        return d
    }

    static func checkSSH(_ a: [String: Any]) -> (String, Bool) {
        let host = a["host"] as? String ?? "", user = a["user"] as? String ?? ""
        let port = a["port"] as? String ?? "22"
        guard isIPv4(host), isName(user), isPort(port) else { return ("host must be an IPv4 address, user a plain name, port a number", true) }
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes", "-p", port]
        if let id = a["identity"] as? String, !id.isEmpty {
            guard id.range(of: #"^[~A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil else { return ("identity: a plain path", true) }
            args += ["-i", id.replacingOccurrences(of: "~", with: NSHomeDirectory())]
        }
        if let jh = a["jump_host"] as? String, !jh.isEmpty {
            let ju = a["jump_user"] as? String ?? user, jp = a["jump_port"] as? String ?? "22"
            guard isIPv4(jh), isName(ju), isPort(jp) else { return ("jump_host must be IPv4, jump_user a plain name", true) }
            args += ["-o", "ProxyCommand=/usr/bin/ssh -p \(jp) -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -W %h:%p \(ju)@\(jh)"]
        }
        let r = runSync("/usr/bin/ssh", args + ["\(user)@\(host)", "true"])
        if r.status == 0 { return ("SSH works", false) }
        var why = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if why.contains("Host key verification failed") {
            why += "\nThe server's host key is not in ~/.ssh/known_hosts. Ask the user to run `ssh \(user)@\(host)` once in Terminal and accept the key."
        }
        return ("SSH failed: \(why)", true)
    }

    static func checkProxy(_ a: [String: Any]) -> (String, Bool) {
        let host = a["host"] as? String ?? "", port = a["port"] as? String ?? ""
        guard isIPv4(host), isPort(port) else { return ("host must be an IPv4 address and port a number", true) }
        let r = runSync("/usr/bin/nc", ["-z", "-G", "5", host, port])
        return r.status == 0 ? ("The proxy answers on \(host):\(port)", false) : ("No answer from \(host):\(port)", true)
    }

    static func checkExit(_ tunAddr: String) -> (String, Bool) {
        // Only an address that sits on a utun right now, and the request is bound
        // to that interface by name: a Wi-Fi address can never reveal the direct IP.
        switch probeExit(tunAddr: tunAddr) {
        case .notTun:
            return ("\(tunAddr) is not on any utun interface right now (see detect). Only TUN interfaces can be checked.", true)
        case .noAnswer:
            return ("No answer through \(tunAddr): is the TUN app on and connected?", true)
        case .seen(let ip, let country):
            let ai = probeAIHosts(tunAddr: tunAddr).map { ["host": $0.host, "ip": $0.ip, "country": $0.country] }
            let tz = macTimeZone()
            return (json(["exit_ip": ip, "exit_country": country, "seen_by_ai_services": ai,
                          "mac_time_zone": tz.zone, "mac_time_zone_country": tz.country]), false)
        }
    }

    /// The guard's own reading of a config ("KEY=value" lines), or the error.
    static func effective(_ conf: String) -> (ok: Bool, text: String) {
        guard let tmp = writeTemp(conf) else { return (false, "could not write a temporary file") }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let r = runSync("/bin/bash", [Paths.bundledCLI, "config"], env: ["TUNLOCK_CONF": tmp])
        let text = r.output.replacingOccurrences(of: "tunlock: ", with: "").replacingOccurrences(of: tmp + ":", with: "line ")
        return (r.status == 0, text)
    }

    /// What Tunlock's form will actually save for this config, and any setting
    /// that would come out different. Validation and saving must see the same file.
    static func roundTrip(_ conf: String) -> (saved: String, changed: [String], merged: String) {
        var parsed = TunConfig.parse(conf)
        if !parsed.isProxy, parsed.identity.isEmpty, let installed = TunConfig.loadInstalled(), !installed.isProxy {
            parsed.identity = installed.identity  // keep the user's key file; the agent never saw its path
        }
        var changed: [String] = []
        // Advanced keys have no field in the form: an agent may not set or change
        // them. Ones it leaves out keep their installed values.
        let installed = TunConfig.loadInstalled()?.extras ?? []
        let installedExtras = Dictionary(installed.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        for (key, value) in parsed.extras where installedExtras[key] != value {
            changed.append("\(key): advanced setting, change it by hand in tunlock.conf, not through MCP "
                           + "(installed: \(installedExtras[key] ?? "unset"), draft: \(value))")
        }
        var merged = conf.hasSuffix("\n") ? conf : conf + "\n"
        for item in installed where !parsed.extras.contains(where: { $0.key == item.key }) {
            parsed.extras.append(item)
            merged += "\(item.key)=\"\(item.value)\"\n"
        }
        let saved = parsed.render()
        let a = lines(effective(merged).text), b = lines(effective(saved).text)
        changed += a.keys.sorted().filter { $0 != "TUN_IFACE" && $0 != "SSH_IDENTITY" && a[$0] != b[$0] }
            .map { "\($0): \(a[$0] ?? "") -> \(b[$0] ?? "")" }
        return (saved, changed, merged)
    }

    static func lines(_ text: String) -> [String: String] {
        var d: [String: String] = [:]
        for l in text.split(separator: "\n") {
            if let eq = l.firstIndex(of: "=") { d[String(l[..<eq])] = String(l[l.index(after: eq)...]) }
        }
        return d
    }

    /// "VALID" plus effective settings and rule previews, or "INVALID: reason".
    static func validate(_ conf: String) -> String? {
        guard effective(conf).ok else { return "INVALID: " + effective(conf).text }
        let (saved, changed, merged) = roundTrip(conf)
        let e = effective(merged)
        if !changed.isEmpty {
            return "INVALID: this draft cannot be applied as written:\n" + changed.joined(separator: "\n")
        }
        guard let tmp = writeTemp(saved) else { return nil }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        var out = "VALID\n\nEffective settings:\n" + e.text
        for phase in ["block", "probe", "open"] {
            let r = runSync("/bin/bash", [Paths.bundledCLI, "render-rules", phase, "utun9", "en0"], env: ["TUNLOCK_CONF": tmp])
            out += "\nFirewall rules, phase \(phase):\n" + r.output
        }
        return out
    }

    static func propose(_ a: [String: Any]) -> (String, Bool) {
        let conf = a["config"] as? String ?? ""
        let report = validate(conf) ?? "could not validate"
        guard report.hasPrefix("VALID") else { return (report + "\nFix it and call propose_config again.", true) }
        // Store exactly what the form will show and save.
        let saved = roundTrip(conf).saved
        let note = (a["note"] as? String ?? "").replacingOccurrences(of: "\n", with: " ").prefix(200)
        let draft = "# Draft from an AI agent via MCP" + (note.isEmpty ? "" : ": \(note)") + "\n" + saved
        do {
            try FileManager.default.createDirectory(atPath: Paths.draftDir, withIntermediateDirectories: true)
            try draft.write(toFile: Paths.draft, atomically: true, encoding: .utf8)
        } catch {
            return ("Could not save the draft: \(error.localizedDescription)", true)
        }
        return ("Draft saved. Tunlock shows it in its settings; the user reviews it and presses Save and apply. Tell the user to check the Tunlock window. Nothing is active until they do.", false)
    }

    // MARK: helpers

    static func writeTemp(_ text: String) -> String? {
        let path = NSTemporaryDirectory() + "tunlock-mcp-\(UUID().uuidString).conf"
        return (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil ? path : nil
    }

    static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    static func isIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 4 && p.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
    static func isPort(_ s: String) -> Bool { Int(s).map { (1...65535).contains($0) } ?? false }
    static func isName(_ s: String) -> Bool { s.range(of: #"^[A-Za-z_][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil }

    static func runSync(_ path: String, _ args: [String], env: [String: String]? = nil) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return RunResult(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RunResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
