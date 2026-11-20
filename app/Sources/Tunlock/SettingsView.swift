import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: StatusModel
    @State private var config = TunConfig.loadInstalled() ?? TunConfig()
    @State private var passwordless = FileManager.default.fileExists(atPath: Paths.sudoers)
        || !FileManager.default.fileExists(atPath: Paths.config)
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var tuns: [TunInterface] = tunInterfaces()
    @State private var sshCheck: Check = .idle
    @State private var ipCheck: Check = .idle
    @State private var seenIP: String?
    @State private var proxyCheck: Check = .idle
    @State private var saving = false
    @State private var saveError: String?
    @State private var saved = false
    @State private var confirmUninstall = false
    @State private var newNet = ""
    @AppStorage(HopNames.entryKey) private var entryName = ""
    @AppStorage(HopNames.exitKey) private var exitName = ""
    @AppStorage("showFlag") private var showFlag = true

    enum Check: Equatable {
        case idle, running, ok(String), failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !model.installed { welcome }
                upstreamSection
                if config.isProxy { proxySection } else { serverSection }
                tunnelSection
                checkSection
                exceptionsSection
                behaviourSection
            }
            .formStyle(.grouped)
            Divider()
            bottomBar.padding(16)
        }
        .frame(width: 560, height: model.installed ? 640 : 760)
        .onChange(of: config) { _ in saved = false }
    }

    // MARK: sections

    private var welcome: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Welcome to Tunlock", "Добро пожаловать в Tunlock")).font(.title2.weight(.semibold))
                Text(L("Tunlock lets this Mac reach the internet only through your own server over SSH. If the tunnel breaks, the internet stays blocked instead of quietly using your real IP.",
                       "Tunlock пускает Mac в интернет только через ваш сервер по SSH. Если туннель обрывается, интернет остаётся заблокированным и не уходит молча через ваш настоящий IP."))
                    .foregroundStyle(.secondary)
                Text(L("1. Enter your server.  2. Turn on your TUN app (Karing, sing-box…) and pick its interface.  3. Save. Then switch modes from the menu bar.",
                       "1. Укажите сервер.  2. Включите TUN-приложение (Karing, sing-box…) и выберите его интерфейс.  3. Сохраните. Дальше режимы переключаются из строки меню."))
                    .font(.callout)
            }
            .padding(.vertical, 4)
        }
    }

    private var serverSection: some View {
        Section {
            TextField(config.cascade ? L("Exit server IP", "IP сервера выхода") : L("Server IP", "IP сервера"),
                      text: $config.vpsIP, prompt: Text("203.0.113.10"))
            TextField(L("Exit name (shown in the menu)", "Название выхода (для меню)"), text: $exitName,
                      prompt: Text(L("e.g. Amsterdam", "например, Амстердам")))
            TextField(L("SSH user", "Пользователь SSH"), text: $config.sshUser)
            TextField(L("SSH port", "Порт SSH"), text: $config.sshPort)
            HStack {
                TextField(L("SSH key", "SSH-ключ"), text: $config.identity, prompt: Text(L("agent / default", "агент / по умолчанию")))
                Button(L("Choose…", "Выбрать…"), action: chooseKey)
            }
            Toggle(L("Enter through a relay server (cascade)", "Вход через промежуточный сервер (каскад)"), isOn: $config.cascade)
            if config.cascade {
                TextField(L("Relay IP", "IP сервера входа"), text: $config.jumpHost, prompt: Text("198.51.100.7"))
                TextField(L("Relay user", "Пользователь на входе"), text: $config.jumpUser, prompt: Text(config.sshUser))
                TextField(L("Relay port", "Порт входа"), text: $config.jumpPort)
                TextField(L("Entry name (shown in the menu)", "Название входа (для меню)"), text: $entryName,
                          prompt: Text(L("e.g. Warsaw", "например, Варшава")))
            }
            HStack {
                Button(L("Check SSH", "Проверить SSH"), action: checkSSH)
                    .disabled(config.vpsIP.isEmpty || sshCheck == .running)
                checkLabel(sshCheck)
            }
        } header: {
            Text(L("Server", "Сервер"))
        } footer: {
            FooterText(config.cascade
                ? L("SSH goes Mac → relay → exit server. Outside the tunnel only the relay is reachable, and the internet opens only when traffic exits with the exit server's IP. If the relay is up but the exit server is down, the internet stays blocked. Both server keys must be in known_hosts.",
                    "SSH идёт так: Mac → сервер входа → сервер выхода. Вне туннеля доступен только сервер входа. Интернет открывается, только если трафик выходит с IP сервера выхода. Если вход работает, а выход упал, интернет остаётся заблокированным. Ключи обоих серверов должны быть в known_hosts.")
                : L("Use the IP address, not a name: DNS is blocked while protected. The server key must already be in known_hosts. If the check says it is not, run ssh user@IP once in Terminal.",
                    "Укажите IP, а не имя: в защищённом режиме DNS заблокирован. Ключ сервера должен уже быть в known_hosts. Если проверка скажет, что его нет, один раз выполните ssh пользователь@IP в Терминале."))
        }
    }

    private var upstreamSection: some View {
        Section {
            Picker(L("How your TUN app goes out", "Как TUN-приложение выходит в интернет"), selection: $config.upstream) {
                Text(L("Through my server over SSH", "Через мой сервер по SSH")).tag("ssh")
                Text(L("Straight to a proxy (no server)", "Напрямую через прокси (без сервера)")).tag("proxy")
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text(L("Connection", "Подключение"))
        } footer: {
            FooterText(config.isProxy
                ? L("You have a proxy (IP, port, login, password) set up in your TUN app, e.g. Karing. Tunlock lets the Mac reach only that proxy and opens the internet only when traffic exits with the proxy's IP.",
                    "У вас есть прокси (IP, порт, логин, пароль), настроенный в TUN-приложении, например в Karing. Tunlock разрешит Mac связываться только с этим прокси и откроет интернет, только когда трафик выходит с IP прокси.")
                : L("You have your own server (VPS) you can SSH into. Tunlock keeps the SSH tunnel up; your TUN app sends traffic into it.",
                    "У вас есть свой сервер (VPS) с доступом по SSH. Tunlock держит SSH-туннель, а TUN-приложение отправляет в него трафик."))
        }
    }

    private var proxySection: some View {
        Section {
            TextField(L("Proxy IP", "IP прокси"), text: $config.proxyHost, prompt: Text("198.51.100.20"))
            TextField(L("Proxy port", "Порт прокси"), text: $config.proxyPort, prompt: Text("8080"))
            HStack {
                Button(L("Check proxy", "Проверить прокси"), action: checkProxy)
                    .disabled(config.proxyHost.isEmpty || config.proxyPort.isEmpty || proxyCheck == .running)
                checkLabel(proxyCheck)
            }
        } header: {
            Text(L("Proxy", "Прокси"))
        } footer: {
            FooterText(L("Only the IP and port. The login and password stay in your TUN app: Tunlock never needs or sees them. Use the IP address, not a name: DNS is blocked while protected.",
                         "Только IP и порт. Логин и пароль остаются в TUN-приложении: Tunlock они не нужны, и он их не видит. Указывайте IP, а не имя: в защищённом режиме DNS заблокирован."))
        }
    }

    private var tunnelSection: some View {
        Section {
            if !config.isProxy {
                Picker(L("Through SSH", "Через SSH"), selection: $config.forward) {
                    ForEach(ForwardKind.allCases) { Text($0.title).tag($0) }
                }
                switch config.forward {
                case .shadowsocks:
                    TextField(L("Local port", "Локальный порт"), text: $config.localPort)
                    TextField(L("Proxy port on the server", "Порт прокси на сервере"), text: $config.remotePort, prompt: Text("8388"))
                case .socks:
                    TextField(L("Local SOCKS port", "Локальный SOCKS-порт"), text: $config.localPort)
                case .custom:
                    TextField("SSH_FORWARD", text: $config.customForward, prompt: Text("-L 127.0.0.1:1080:127.0.0.1:8388"))
                }
            }
            Picker(L("TUN app to start and stop", "TUN-приложение (вкл/выкл вместе с Tunlock)"), selection: $config.tunService) {
                Text(L("Don't control", "Не управлять")).tag("")
                ForEach(vpnServices(), id: \.self) { Text($0).tag($0) }
                if !config.tunService.isEmpty, !vpnServices().contains(config.tunService) {
                    Text(config.tunService).tag(config.tunService)
                }
            }
            HStack {
                Picker(L("TUN interface", "TUN-интерфейс"), selection: tunSelection) {
                    Text(L("Choose…", "Выберите…")).tag("")
                    ForEach(tuns) { t in Text("\(t.name) · \(t.address)/\(t.prefix)").tag(t.address + "|" + t.mask) }
                    if !config.tunAddr.isEmpty, !tuns.contains(where: { $0.address == config.tunAddr }) {
                        Text("\(config.tunAddr) " + L("(not up now)", "(сейчас не поднят)")).tag(config.tunAddr + "|" + config.tunMask)
                    }
                }
                Button {
                    tuns = tunInterfaces()
                } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Rescan interfaces", "Найти интерфейсы заново"))
            }
        } header: {
            Text(L("Tunnel", "Туннель"))
        } footer: {
            FooterText(config.isProxy
                 ? L("Turn your TUN app on with the proxy profile, then pick its interface here. The number (utunN) may change later; the address may not.",
                     "Включите TUN-приложение с профилем прокси и выберите здесь его интерфейс. Номер utunN потом может меняться, адрес — нет.")
                 : config.forward == .custom
                 ? L("Only -L and -D are accepted.", "Допускаются только -L и -D.")
                 : L("In your TUN app, point the proxy at 127.0.0.1:\(config.localPort). Turn the TUN app on, then pick its interface here. The number (utunN) may change later; the address may not.",
                     "В TUN-приложении укажите прокси 127.0.0.1:\(config.localPort). Включите его и выберите здесь интерфейс. Номер utunN потом может меняться, адрес — нет."))
        }
    }

    private var checkSection: some View {
        Section {
            TextField(L("Expected exit IP", "Ожидаемый выходной IP"), text: $config.expectedEgress,
                      prompt: Text(config.effectiveEgress.isEmpty
                                   ? (config.isProxy ? L("same as the proxy", "как у прокси") : L("same as server", "как у сервера"))
                                   : config.effectiveEgress))
            HStack {
                Button(L("Check exit IP now", "Проверить IP сейчас"), action: checkIP)
                    .disabled(config.tunAddr.isEmpty || ipCheck == .running)
                checkLabel(ipCheck)
            }
            if let ip = seenIP, ip != config.effectiveEgress {
                Button(L("Use \(ip) as the expected exit IP", "Использовать \(ip) как ожидаемый выходной IP")) {
                    config.expectedEgress = ip
                    ipCheck = .ok(L("\(ip): will be expected", "\(ip): будет ожидаться"))
                }
                .buttonStyle(.link)
            }
        } header: {
            Text(L("Exit check", "Проверка выхода"))
        } footer: {
            FooterText(L("Tunlock asks 1.1.1.1 which IP the tunnel exits from, and opens the internet only when it matches.",
                   "Tunlock спрашивает у 1.1.1.1, с какого IP выходит туннель, и открывает интернет только при совпадении."))
        }
    }

    private var exceptionsSection: some View {
        Section {
            ForEach(config.bypassNets, id: \.self) { net in
                HStack {
                    Image(systemName: "network").foregroundStyle(.secondary)
                    Text(net).monospacedDigit()
                    Spacer()
                    Button {
                        config.bypassNets.removeAll { $0 == net }
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help(L("Remove", "Убрать"))
                }
            }
            HStack {
                TextField(L("Network", "Сеть"), text: $newNet, prompt: Text("192.168.0.0/24"))
                    .onSubmit(addNet)
                Button(L("Add", "Добавить"), action: addNet).disabled(!isCIDR(newNet))
            }
            if let lan = currentLocalNetwork(), !config.bypassNets.contains(lan) {
                Button(L("Add the current local network (\(lan))", "Добавить текущую локальную сеть (\(lan))")) {
                    config.bypassNets.append(lan)
                }
                .buttonStyle(.link)
            }
            ForEach($config.bypassDNS) { $rule in
                HStack {
                    TextField(L("Domain", "Домен"), text: $rule.domain, prompt: Text("corp.example"))
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField(L("DNS server", "DNS-сервер"), text: $rule.server, prompt: Text("192.168.0.1"))
                    Button {
                        config.bypassDNS.removeAll { $0.id == rule.id }
                    } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                }
                .labelsHidden()
            }
            Button(L("Add a DNS rule for a domain", "Добавить DNS для домена")) {
                config.bypassDNS.append(DNSRule(domain: "", server: ""))
            }
            .buttonStyle(.link)
        } header: {
            Text(L("Exceptions: around the tunnel", "Исключения: мимо туннеля"))
        } footer: {
            FooterText(L("These networks are reached directly through your Wi-Fi/Ethernet on any port (HTTP, HTTPS, SSH, custom ports), even while the tunnel is down. Use them for office and home networks. Traffic to them does not go through your server. DNS rules send names in a domain, and its subdomains, to the given server, for example corp.example → 192.168.0.1.",
                         "Эти сети доступны напрямую через Wi‑Fi/Ethernet на любом порту (HTTP, HTTPS, SSH, нестандартные порты), даже когда туннель лежит. Подходит для офисной и домашней сети. Трафик к ним идёт мимо вашего сервера. DNS-правило отправляет имена домена и его поддоменов на указанный сервер, например corp.example → 192.168.0.1."))
        }
    }

    private func addNet() {
        let net = newNet.trimmingCharacters(in: .whitespaces)
        guard isCIDR(net), !config.bypassNets.contains(net) else { return }
        config.bypassNets.append(net)
        newNet = ""
    }

    private var behaviourSection: some View {
        Section {
            Toggle(L("Switch modes without a password", "Переключать режимы без пароля"), isOn: $passwordless)
            Toggle(L("Show the exit country flag in the menu bar", "Показывать флаг страны выхода в строке меню"), isOn: $showFlag)
            Toggle(L("Open Tunlock at login", "Открывать Tunlock при входе"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { saveError = error.localizedDescription }
                }
        } header: {
            Text(L("Behaviour", "Поведение"))
        } footer: {
            FooterText(L("Protection is enforced by a background service, so it works even when this app is closed. After a restart in protected mode, the internet stays blocked until the tunnel is verified.",
                   "Защиту держит фоновая служба: она работает и при закрытом приложении. После перезагрузки в защищённом режиме интернет остаётся закрытым, пока туннель не пройдёт проверку."))
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            if model.installed {
                Button(L("Uninstall…", "Удалить…"), role: .destructive) { confirmUninstall = true }
                    .confirmationDialog(L("Remove Tunlock's service and rules?", "Удалить службу и правила Tunlock?"),
                                        isPresented: $confirmUninstall) {
                        Button(L("Uninstall", "Удалить"), role: .destructive) { model.uninstall() }
                    } message: {
                        Text(L("Direct internet will be allowed again, and the settings deleted.", "Прямой интернет снова будет разрешён, настройки удалятся."))
                    }
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            } else if saved {
                Label(L("Applied", "Применено"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if model.needsUpdate {
                Text(L("A newer service is bundled. Save to update it.", "В приложении более новая служба. Сохраните, чтобы обновить."))
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            if saving { ProgressView().controlSize(.small) }
            Button(L("Save and apply", "Сохранить и применить"), action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || config.tunAddr.isEmpty
                          || (config.isProxy ? config.proxyHost.isEmpty || config.proxyPort.isEmpty : config.vpsIP.isEmpty))
        }
    }

    // MARK: helpers

    private var tunSelection: Binding<String> {
        Binding(
            get: { config.tunAddr.isEmpty ? "" : config.tunAddr + "|" + config.tunMask },
            set: { value in
                let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                config.tunAddr = parts.first ?? ""
                config.tunMask = parts.count > 1 ? parts[1] : ""
            })
    }

    @ViewBuilder
    private func checkLabel(_ c: Check) -> some View {
        switch c {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .ok(let text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let text): Label(text, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                .lineLimit(3).textSelection(.enabled)
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            config.identity = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    private func checkSSH() {
        sshCheck = .running
        let c = config
        Task {
            var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "StrictHostKeyChecking=yes", "-p", c.sshPort]
            let key = c.identity.replacingOccurrences(of: "~", with: NSHomeDirectory())
            if !c.identity.isEmpty { args += ["-i", key] }
            if c.cascade {
                let user = c.jumpUser.isEmpty ? c.sshUser : c.jumpUser
                args += ["-o", "ProxyCommand=/usr/bin/ssh -p \(c.jumpPort) -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=6"
                         + (c.identity.isEmpty ? "" : " -i \(key)") + " -W %h:%p \(user)@\(c.jumpHost)"]
            }
            let r = await run("/usr/bin/ssh", args + ["\(c.sshUser)@\(c.vpsIP)", "true"])
            if r.ok { sshCheck = .ok(L("SSH works", "SSH работает")); return }
            let out = r.output
            if c.cascade, out.contains("open failed") || out.contains("stdio forwarding failed") {
                sshCheck = .failed(L("Relay works, but it cannot reach the exit server", "Вход работает, но не достаёт до сервера выхода"))
            } else if out.contains("Host key verification failed") || out.contains("No ED25519 host key") || out.contains("No RSA host key") {
                sshCheck = .failed(L("Server key unknown: run ssh \(c.sshUser)@\(c.vpsIP) in Terminal once",
                                     "Ключ сервера неизвестен: один раз выполните ssh \(c.sshUser)@\(c.vpsIP) в Терминале"))
            } else if out.contains("Permission denied") {
                sshCheck = .failed(L("Key rejected by the server", "Сервер не принял ключ"))
            } else {
                sshCheck = .failed(out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "")
            }
        }
    }

    private func checkIP() {
        ipCheck = .running
        let c = config
        Task {
            let r = await run("/usr/bin/curl", ["-4fsS", "--noproxy", "*", "--interface", c.tunAddr,
                                                "--connect-timeout", "4", "--max-time", "6", "https://1.1.1.1/cdn-cgi/trace"])
            let ip = r.output.split(separator: "\n").first { $0.hasPrefix("ip=") }.map { String($0.dropFirst(3)) }
            seenIP = ip
            if let ip, ip == c.effectiveEgress {
                ipCheck = .ok(L("\(ip): matches", "\(ip): совпадает"))
            } else if let ip {
                ipCheck = .failed(L("\(ip): does not match \(c.effectiveEgress)", "\(ip): не совпадает с \(c.effectiveEgress)"))
            } else {
                ipCheck = .failed(L("No answer through the tunnel", "Нет ответа через туннель"))
            }
        }
    }

    private func checkProxy() {
        proxyCheck = .running
        let c = config
        Task {
            let r = await run("/usr/bin/nc", ["-z", "-G", "4", c.proxyHost, c.proxyPort])
            proxyCheck = r.ok ? .ok(L("Proxy answers", "Прокси отвечает"))
                              : .failed(L("No answer from \(c.proxyHost):\(c.proxyPort)", "Нет ответа от \(c.proxyHost):\(c.proxyPort)"))
        }
    }

    private func save() {
        saving = true
        saveError = nil
        Task {
            saveError = await model.apply(config, passwordless: passwordless)
            saving = false
            saved = saveError == nil
        }
    }
}

enum LeakResult {
    case pass, fail, incomplete, baseline, didNotRun

    init(output: String) {
        let result = output.split(separator: "\n").last { $0.hasPrefix("RESULT=") }.map { String($0.dropFirst(7)) }
        switch result {
        case "pass": self = .pass
        case "fail": self = .fail
        case "incomplete": self = .incomplete
        case "baseline": self = .baseline
        default: self = .didNotRun
        }
    }

    var title: String {
        switch self {
        case .pass: return L("No leaks found", "Утечек не найдено")
        case .fail: return L("Leak or broken tunnel found", "Найдена утечка или туннель не работает")
        case .incomplete: return L("Test incomplete: required checks could not run", "Тест не завершён: обязательные проверки не выполнились")
        case .baseline: return L("Direct mode: reference only, nothing is protected", "Прямой режим: справочно, защиты нет")
        case .didNotRun: return L("The test did not run", "Тест не запустился")
        }
    }

    var symbol: String {
        switch self {
        case .pass: return "checkmark.shield.fill"
        case .fail: return "xmark.shield.fill"
        case .incomplete, .didNotRun: return "questionmark.diamond.fill"
        case .baseline: return "shield.slash"
        }
    }

    var color: Color {
        switch self {
        case .pass: return .green
        case .fail: return .red
        case .incomplete, .didNotRun: return .orange
        case .baseline: return .secondary
        }
    }
}

struct LeakTestView: View {
    @EnvironmentObject var model: StatusModel

    var body: some View {
        let output = model.testOutput ?? ""
        let lines = output.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("RESULT=") && !$0.hasPrefix("SKIPPED=") }
        let result = LeakResult(output: output)
        let skipped = lines.filter { $0.hasPrefix("SKIP") }.count
        VStack(alignment: .leading, spacing: 12) {
            Label(result.title, systemImage: result.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(result.color)
            if result == .pass, skipped > 0 {
                Text(L("\(skipped) check(s) could not run on this network, see SKIP below.",
                       "Проверок, которые нельзя выполнить в этой сети: \(skipped), см. SKIP ниже."))
                    .font(.callout).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).foregroundStyle(color(of: line))
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L("PASS: behaved as required. FAIL: leak or broken tunnel. SKIP: could not be checked here. INFO: reference only, in direct mode.",
                   "PASS — всё как надо. FAIL — утечка или туннель не работает. SKIP — здесь проверить нельзя. INFO — справочно, в прямом режиме."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 640, height: 360)
    }

    private func color(of line: String) -> Color {
        if line.hasPrefix("PASS") { return .green }
        if line.hasPrefix("FAIL") { return .red }
        if line.hasPrefix("SKIP") { return .orange }
        if line.hasPrefix("INFO") { return .secondary }
        return .primary
    }
}

/// Section notes: left-aligned and quiet, like System Settings.
struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
