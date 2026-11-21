import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: StatusModel
    @State private var config = TunConfig.loadDraft() ?? TunConfig.loadInstalled() ?? TunConfig()
    /// The draft version shown in this form (nil: the installed config).
    @State private var loadedDraft: String? = try? String(contentsOfFile: Paths.draft, encoding: .utf8)
    private var fromAgent: Bool { loadedDraft != nil }
    /// A newer draft than the one in the form arrived.
    private var newerDraft: String? {
        guard let id = model.draftID, id != loadedDraft else { return nil }
        return id
    }
    @State private var passwordless = FileManager.default.fileExists(atPath: Paths.sudoers)
        || !FileManager.default.fileExists(atPath: Paths.config)
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var tuns: [TunInterface] = tunInterfaces()
    @State private var sshCheck: Check = .idle
    @State private var ipCheck: Check = .idle
    @State private var seenIP: String?
    @State private var seenCountry = ""
    @State private var tab: Tab
    /// Agent drafts open on a one-screen review; the full tabs are one click away.
    @State private var showAllSettings = false
    @State private var applyStage: ApplyStage = .idle

    enum ApplyStage: Equatable {
        case idle, saving, turningOn
        case done(text: String, success: Bool)
    }
    @AppStorage("notify") private var notify = true
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

    enum Tab: Hashable { case connection, exit, exceptions, activity, general }

    init(tab: Tab = .connection) { _tab = State(initialValue: tab) }

    var body: some View {
        VStack(spacing: 0) {
            if let draft = newerDraft { newDraftBanner(draft) }
            if fromAgent, !showAllSettings {
                draftReview
            } else {
                if fromAgent { agentDraftBanner } else if !model.installed, newerDraft == nil { welcome }
                fullSettings
            }
        }
        .frame(width: 600, height: 620)
        .onChange(of: config) { _ in saved = false }
    }

    @ViewBuilder
    private var fullSettings: some View {
            TabView(selection: $tab) {
                Form {
                    upstreamSection
                    if config.isProxy { proxySection } else { serverSection }
                    tunnelSection
                }
                .formStyle(.grouped)
                .tabItem { Text(L("Connection", "Подключение")) }.tag(Tab.connection)

                Form { exitSection }
                    .formStyle(.grouped)
                    .tabItem { Text(L("Exit", "Выход")) }.tag(Tab.exit)

                Form { exceptionsSection }
                    .formStyle(.grouped)
                    .tabItem { Text(L("Exceptions", "Исключения")) }.tag(Tab.exceptions)

                ActivityView()
                    .tabItem { Text(L("Activity", "Журнал")) }.tag(Tab.activity)

                Form { behaviourSection; dangerSection }
                    .formStyle(.grouped)
                    .tabItem { Text(L("General", "Общие")) }.tag(Tab.general)
            }
            .padding(.top, 8)
            Divider()
            bottomBar.padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: agent draft review

    /// "The agent set it up, I confirm": the few facts that matter, one button.
    private var draftReview: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("The AI agent prepared Tunlock", "ИИ-агент подготовил Tunlock")).font(.title3.weight(.semibold))
                    Text(L("Check these points. Nothing is applied until you press the button below.",
                           "Проверьте эти пункты. Ничего не применится, пока вы не нажмёте кнопку внизу."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Form {
                Section {
                    LabeledContent(L("Connection", "Подключение"), value: connectionSummary)
                    LabeledContent(L("TUN app", "TUN-приложение")) { tunSummary }
                    LabeledContent(L("Expected exit", "Ожидаемый выход"), value: config.exitDescription)
                    LabeledContent(L("Exit right now", "Выход сейчас")) {
                        HStack(spacing: 8) {
                            checkLabel(ipCheck)
                            Button(L("Check", "Проверить"), action: checkIP)
                                .disabled(config.tunAddr.isEmpty || ipCheck == .running)
                        }
                    }
                    if let ip = seenIP, !config.exitMatches(ip: ip, country: seenCountry) {
                        Button(L("Pin this exit instead: \(ip) \(flagEmoji(seenCountry))",
                                 "Закрепить вместо этого выход: \(ip) \(flagEmoji(seenCountry))"), action: pinSeen)
                    }
                    aiSeenRows
                }
                if !config.extras.isEmpty {
                    Section {
                        ForEach(config.extras, id: \.key) { LabeledContent($0.key, value: $0.value) }
                    } header: {
                        Text(L("Advanced settings (kept from your config)", "Расширенные параметры (сохранены из вашего конфига)"))
                    }
                }
                Section {
                    if config.bypassNets.isEmpty && config.bypassDNS.isEmpty {
                        Text(L("Nothing: every connection goes through the tunnel.", "Ничего: все соединения идут через туннель."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(config.bypassNets, id: \.self) { Label($0, systemImage: "network") }
                    ForEach(config.bypassDNS) { Label("\($0.domain) → \($0.server)", systemImage: "character.cursor.ibeam") }
                } header: {
                    Text(L("Goes directly, around the tunnel", "Пойдёт напрямую, мимо туннеля"))
                }
            }
            .formStyle(.grouped)
            .onAppear { if ipCheck == .idle, !config.tunAddr.isEmpty { checkIP() } }

            Divider()
            HStack(spacing: 12) {
                switch applyStage {
                case .idle:
                    Button(L("All settings…", "Все настройки…")) { showAllSettings = true }
                    Button(L("Discard", "Отклонить")) {
                        removeDraft(ifStill: loadedDraft)
                        loadedDraft = nil
                        config = TunConfig.loadInstalled() ?? TunConfig()
                        resetCheck()
                    }
                    Spacer()
                    if let blocker = saveBlocker {
                        Text(blocker.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Button(L("Apply and turn on", "Применить и включить"), action: applyAndTurnOn)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(saveBlocker != nil)
                case .saving, .turningOn:
                    ProgressView().controlSize(.small)
                    Text(applyStage == .saving
                         ? L("Saving and installing the service…", "Сохраняю и устанавливаю службу…")
                         : L("Turning on: firewall, then the tunnel, then checking the exit…", "Включаю: файрвол, затем туннель, затем проверка выхода…"))
                        .foregroundStyle(.secondary)
                    Spacer()
                case .done(let text, let success):
                    Label(text, systemImage: success ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(success ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(success ? L("Done", "Готово") : L("Back", "Назад")) {
                        if success { loadedDraft = nil; Windows.shared.close("settings") } else { applyStage = .idle }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private var connectionSummary: String {
        if config.isProxy { return L("Proxy ", "Прокси ") + "\(clean(config.proxyHost)):\(clean(config.proxyPort))" }
        var s = L("Own server ", "Свой сервер ") + clean(config.vpsIP) + L(" over SSH", " по SSH")
        if config.cascade { s += L(", entering via ", ", вход через ") + clean(config.jumpHost) }
        return s
    }

    @ViewBuilder
    private var tunSummary: some View {
        let app = config.tunService.isEmpty ? "" : config.tunService + " · "
        if let t = tuns.first(where: { $0.address == clean(config.tunAddr) }) {
            Label(app + "\(t.name) · \(t.address)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Label(app + clean(config.tunAddr) + L(": not up, turn it on", ": не поднят, включите его"), systemImage: "moon.fill")
                .foregroundStyle(.orange)
        }
    }

    /// Save + install, then turn on, then say how it ended, in one flow.
    private func applyAndTurnOn() {
        applyStage = .saving
        let version = loadedDraft, snapshot = config
        Task {
            if let error = await model.apply(snapshot, passwordless: passwordless) {
                applyStage = .done(text: error, success: false)
                return
            }
            removeDraft(ifStill: version)
            applyStage = .turningOn
            // "on" exits 0 only when the guard answered this very request with
            // protected or blocked; anything else is a failure, whatever the old state says.
            let r = await model.turnOn()
            guard r.ok else {
                let why = r.cancelled ? L("Cancelled: Tunlock was not turned on.", "Отменено: Tunlock не включён.")
                    : r.output.split(separator: "\n").last { $0.hasPrefix("tunlock:") }.map(String.init)
                        ?? L("Tunlock could not be turned on.", "Не удалось включить Tunlock.")
                applyStage = .done(text: why, success: false)
                return
            }
            for _ in 0..<30 where model.verdict != .protected {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                model.refresh()
            }
            let s = model.state
            switch model.verdict {
            case .protected:
                let cc = s["egress_country"] ?? ""
                applyStage = .done(text: L("Protected: exit ", "Защищено: выход ") + "\(s["egress_ip"] ?? "") \(flagEmoji(cc)) \(countryName(cc))",
                                   success: true)
            case .blocked:
                applyStage = .done(text: L("Tunlock is on and waits for a verified exit: the internet stays closed until then. Check that the TUN app is on.",
                                           "Tunlock включён и ждёт подтверждённого выхода: до этого интернет закрыт. Проверьте, что TUN-приложение включено."),
                                   success: true)
            default:
                let why = r.output.split(separator: "\n").last { $0.hasPrefix("tunlock:") }.map(String.init)
                applyStage = .done(text: why ?? model.verdict.explanation, success: false)
            }
        }
    }

    // MARK: sections

    /// The values came from an AI agent: say so, and let the user drop them.
    private var agentDraftBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Draft from an AI agent", "Черновик от ИИ-агента")).font(.headline)
                Text(L("An agent filled these settings in. Check every tab; nothing is active until you press Save and apply.",
                       "Эти настройки заполнил агент. Проверьте все вкладки: ничего не действует, пока вы не нажмёте «Сохранить и применить»."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L("Discard", "Отклонить")) {
                removeDraft(ifStill: loadedDraft)
                loadedDraft = nil
                config = TunConfig.loadInstalled() ?? TunConfig()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.08))
    }

    /// A newer draft came in while this form was open: offer it, never swap it in silently.
    private func newDraftBanner(_ draft: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text(L("The AI agent sent a new draft. Loading it replaces what is in the form now.",
                   "ИИ-агент прислал новый черновик. Загрузка заменит то, что сейчас в форме."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L("Load", "Загрузить")) {
                config = TunConfig.parse(draft)
                loadedDraft = draft
                resetCheck()
            }
            .disabled(saving || applyStage != .idle)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.14))
    }

    /// Deletes the draft file only if it is still the version this form handled.
    private func removeDraft(ifStill version: String?) {
        guard let version, (try? String(contentsOfFile: Paths.draft, encoding: .utf8)) == version else { return }
        try? FileManager.default.removeItem(atPath: Paths.draft)
    }

    /// First launch: three steps, one line each, above the tabs.
    private var welcome: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill").font(.system(size: 28)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Set up Tunlock in three steps", "Настройка Tunlock в три шага")).font(.headline)
                Text(L("1. Connection: your server or proxy, and the TUN app's interface.  2. Exit: check and pin it.  3. Save and apply.",
                       "1. Подключение: сервер или прокси и интерфейс TUN-приложения.  2. Выход: проверьте и закрепите.  3. Сохраните."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
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
                Picker(L("TUN app's interface", "Интерфейс TUN-приложения"), selection: tunSelection) {
                    Text(L("Choose…", "Выберите…")).tag("")
                    ForEach(tuns) { t in Text("\(t.name) · \(t.address)/\(t.prefix)").tag(t.address + "|" + t.mask) }
                    if !config.tunAddr.isEmpty, !tuns.contains(where: { $0.address == config.tunAddr }) {
                        Text("\(config.tunAddr) " + L("(not up now)", "(сейчас не поднят)")).tag(config.tunAddr + "|" + config.tunMask)
                    }
                }
                Button {
                    rescanTuns()
                } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Rescan interfaces", "Найти интерфейсы заново"))
            }
            .onAppear { if config.tunAddr.isEmpty { rescanTuns() } }
            // Until an interface is chosen, keep looking: turning the TUN app on is enough.
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                if config.tunAddr.isEmpty { rescanTuns() }
            }
            tunStatus
        } header: {
            Text(L("Tunnel", "Туннель"))
        } footer: {
            FooterText(config.isProxy
                 ? L("Turn your TUN app on with the proxy profile, in TUN mode. Tunlock spots its interface and asks you to confirm it.",
                     "Включите TUN-приложение с профилем прокси в режиме TUN. Tunlock заметит его интерфейс и попросит подтвердить.")
                 : config.forward == .custom
                 ? L("Only -L and -D are accepted.", "Допускаются только -L и -D.")
                 : L("In your TUN app, point the proxy at 127.0.0.1:\(config.localPort) and turn it on in TUN mode. Tunlock spots its interface and asks you to confirm it.",
                     "В TUN-приложении укажите прокси 127.0.0.1:\(config.localPort) и включите его в режиме TUN. Tunlock заметит его интерфейс и попросит подтвердить."))
        }
    }

    private var exitSection: some View {
        Group {
            Section {
                Picker(L("Count as my exit", "Своим выходом считать"), selection: $config.exitMode) {
                    ForEach(TunConfig.ExitMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if config.exitMode != .country {
                    TextField(L("Exit IP", "Выходной IP"), text: Binding(
                        get: { config.expectedEgress == "any" ? "" : config.expectedEgress },
                        set: { config.expectedEgress = clean($0) }),
                              prompt: Text(config.isProxy ? (config.proxyHost.isEmpty ? L("same as the proxy", "как у прокси") : config.proxyHost)
                                                          : (config.vpsIP.isEmpty ? L("same as server", "как у сервера") : config.vpsIP)))
                }
                if config.exitMode != .country, !config.expectedEgress.isEmpty, config.expectedEgress != "any",
                   !looksLikeIPv4(config.expectedEgress) {
                    Label(L("This is not an IPv4 address: check for extra characters.",
                            "Это не похоже на IPv4-адрес: проверьте, нет ли лишних символов."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                if config.exitMode != .ip {
                    HStack {
                        TextField(L("Country code", "Код страны"), text: $config.expectedCountry, prompt: Text("US"))
                        if config.expectedCountry.count == 2 {
                            Text("\(flagEmoji(config.expectedCountry)) \(countryName(config.expectedCountry.uppercased()))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(L("Expected exit", "Ожидаемый выход"))
            } footer: {
                FooterText(L("Exact IP is the strictest: any change closes the internet. Choose Country for proxies that rotate their IP: any address in that country is accepted, anything else is blocked.",
                             "Точный IP — самый строгий вариант: любая смена закрывает интернет. «Страна» — для прокси с меняющимся IP: подойдёт любой адрес в этой стране, всё остальное блокируется."))
            }
            Section {
                HStack {
                    Button(L("Check the exit now", "Проверить выход сейчас"), action: checkIP)
                        .disabled(config.tunAddr.isEmpty || ipCheck == .running)
                    checkLabel(ipCheck)
                }
                if let ip = seenIP, !config.exitMatches(ip: ip, country: seenCountry) {
                    Button(L("Pin this exit: \(ip) \(flagEmoji(seenCountry))", "Закрепить этот выход: \(ip) \(flagEmoji(seenCountry))"), action: pinSeen)
                        .buttonStyle(.borderedProminent)
                }
                aiSeenRows
            } header: {
                Text(L("Current exit", "Текущий выход"))
            } footer: {
                FooterText(L("Tunlock asks 1.1.1.1, through the tunnel, which IP and country the traffic exits from, and opens the internet only when they match.",
                             "Tunlock спрашивает у 1.1.1.1 через туннель, с какого IP и из какой страны выходит трафик, и открывает интернет только при совпадении."))
            }
        }
    }

    /// Pin what the check just saw, in the current mode.
    private func pinSeen() {
        guard let ip = seenIP else { return }
        if config.exitMode != .ip, seenCountry.count != 2 {
            ipCheck = .failed(L("The country is unknown: check again", "Страна не определилась: проверьте ещё раз"))
            return
        }
        switch config.exitMode {
        case .ip: config.expectedEgress = ip
        case .country: config.expectedCountry = seenCountry
        case .both: config.expectedEgress = ip; config.expectedCountry = seenCountry
        }
        ipCheck = .ok(L("Pinned: press Save and apply", "Закреплено: нажмите «Сохранить и применить»"))
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
            Toggle(L("Notify when the internet closes or protection returns", "Уведомлять, когда интернет закрылся или защита вернулась"), isOn: $notify)
                .onChange(of: notify) { on in if on { Notifier.requestPermission() } }
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

    @ViewBuilder
    private var dangerSection: some View {
        if model.installed {
            Section {
                Button(L("Uninstall Tunlock…", "Удалить Tunlock…"), role: .destructive) { confirmUninstall = true }
                    .confirmationDialog(L("Remove Tunlock's service and rules?", "Удалить службу и правила Tunlock?"),
                                        isPresented: $confirmUninstall) {
                        Button(L("Uninstall", "Удалить"), role: .destructive) { model.uninstall() }
                    } message: {
                        Text(L("Direct internet will be allowed again, and the settings deleted.", "Прямой интернет снова будет разрешён, настройки удалятся."))
                    }
            } footer: {
                FooterText(L("Removes the background service, its firewall rules and settings. Your TUN app is not touched.",
                             "Удаляет фоновую службу, её правила файрвола и настройки. TUN-приложение не затрагивается."))
            }
        }
    }

    /// Why Save is unavailable, and the tab that fixes it; nil when it can be pressed.
    private var saveBlocker: (text: String, tab: Tab)? {
        if config.isProxy {
            if config.proxyHost.isEmpty || config.proxyPort.isEmpty {
                return (L("Enter the proxy's IP and port", "Укажите IP и порт прокси"), .connection)
            }
        } else if config.vpsIP.isEmpty {
            return (L("Enter your server's IP", "Укажите IP сервера"), .connection)
        }
        if config.tunAddr.isEmpty {
            return (L("Turn the TUN app on in TUN mode and confirm its interface", "Включите TUN-приложение в режиме TUN и подтвердите его интерфейс"), .connection)
        }
        if config.exitMode != .ip, config.expectedCountry.count != 2 {
            return (L("Enter the exit's two-letter country code", "Укажите двухбуквенный код страны выхода"), .exit)
        }
        return nil
    }

    private func tabName(_ t: Tab) -> String {
        switch t {
        case .connection: return L("Connection", "Подключение")
        case .exit: return L("Exit", "Выход")
        case .exceptions: return L("Exceptions", "Исключения")
        case .activity: return L("Activity", "Журнал")
        case .general: return L("General", "Общие")
        }
    }

    /// Whether a TUN interface is seen, and what to do. Tunlock cannot tell which
    /// app owns an interface, so it proposes and the user confirms.
    @ViewBuilder
    private var tunStatus: some View {
        let app = config.tunService.isEmpty ? L("your TUN app", "TUN-приложение") : config.tunService
        if let t = tuns.first(where: { $0.address == config.tunAddr }) {
            Label(L("Using \(t.name) · \(t.address)", "Используется \(t.name) · \(t.address)"), systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        } else if tuns.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Waiting for \(app)… Turn it on in TUN (VPN) mode, not \"system proxy\". Tunlock notices it by itself.",
                       "Жду \(app)… Включите его в режиме TUN (VPN), а не «системный прокси». Tunlock заметит это сам."))
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        } else if config.tunAddr.isEmpty, tuns.count == 1, let t = tuns.first {
            HStack(spacing: 10) {
                Text(L("Found \(t.name) · \(t.address). Is it \(app)'s?", "Найден \(t.name) · \(t.address). Это интерфейс \(app)?"))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(L("Yes, use it", "Да, использовать")) { resetCheck(); config.tunAddr = t.address; config.tunMask = t.mask }
            }
        } else if config.tunAddr.isEmpty {
            Label(L("Several interfaces found: pick \(app)'s in the list. Not sure? Turn \(app) off and on, and see which one appears.",
                    "Найдено несколько интерфейсов: выберите в списке интерфейс \(app). Не уверены? Выключите и включите \(app) и посмотрите, какой появится."),
                  systemImage: "hand.point.up.left.fill")
                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else {
            Label(L("\(config.tunAddr) is not up now: turn \(app) on.", "\(config.tunAddr) сейчас не поднят: включите \(app)."),
                  systemImage: "moon.fill")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Only refreshes the list; choosing stays with the user (see tunStatus).
    private func rescanTuns() { tuns = tunInterfaces() }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            if let blocker = saveBlocker, saveError == nil {
                // One concrete step, and a jump to the tab where it is done.
                Button {
                    tab = blocker.tab
                } label: {
                    Label(blocker.text + (tab == blocker.tab ? "" : " → " + tabName(blocker.tab)), systemImage: "arrow.right.circle")
                        .font(.callout)
                }
                .buttonStyle(.link)
                .fixedSize(horizontal: false, vertical: true)
            } else if let saveError {
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
                .disabled(saving || saveBlocker != nil)
        }
    }

    // MARK: helpers

    private var tunSelection: Binding<String> {
        Binding(
            get: { config.tunAddr.isEmpty ? "" : config.tunAddr + "|" + config.tunMask },
            set: { value in
                let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if (parts.first ?? "") != config.tunAddr { resetCheck() }  // a check of the old tunnel means nothing now
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

    /// Which check is current; results of an older one (another draft, another
    /// interface) are dropped when they arrive.
    @State private var checkToken = UUID()
    /// What the AI services saw in the last check.
    @State private var aiSeen: [(host: String, ip: String, country: String)] = []

    private func checkIP() {
        ipCheck = .running
        seenIP = nil
        seenCountry = ""
        aiSeen = []
        let c = config, token = UUID()
        checkToken = token
        Task {
            let result = await Task.detached { probeExit(tunAddr: c.tunAddr) }.value
            guard token == checkToken, clean(config.tunAddr) == clean(c.tunAddr) else { return }
            if case .seen = result {
                Task {
                    let ai = await Task.detached { probeAIHosts(tunAddr: c.tunAddr) }.value
                    if token == checkToken { aiSeen = ai }
                }
            }
            switch result {
            case .notTun:
                ipCheck = .failed(L("\(clean(c.tunAddr)) is not a TUN interface right now: turn the TUN app on",
                                    "\(clean(c.tunAddr)) сейчас не TUN-интерфейс: включите TUN-приложение"))
            case .noAnswer:
                ipCheck = .failed(L("No answer through the tunnel", "Нет ответа через туннель"))
            case .seen(let ip, let loc):
                seenIP = ip
                seenCountry = loc
                let seen = "\(ip) \(flagEmoji(loc)) \(countryName(loc))"
                ipCheck = c.exitMatches(ip: ip, country: loc)
                    ? .ok(L("\(seen): matches", "\(seen): совпадает"))
                    : .failed(L("\(seen): expected \(c.exitDescription)", "\(seen): ожидается \(c.exitDescription)"))
            }
        }
    }

    /// What Claude, the Anthropic API and ChatGPT see: TUN apps can route them
    /// another way than the probe.
    @ViewBuilder
    private var aiSeenRows: some View {
        ForEach(aiSeen, id: \.host) { s in
            let ok = !s.ip.isEmpty && config.exitMatches(ip: s.ip, country: s.country)
            LabeledContent(L("\(s.host) sees", "\(s.host) видит")) {
                Label(s.ip.isEmpty ? L("no answer", "нет ответа") : "\(s.ip) \(flagEmoji(s.country))",
                      systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
            }
        }
    }

    /// Forget what was checked: the config it belonged to is gone.
    private func resetCheck() {
        checkToken = UUID()
        aiSeen = []
        ipCheck = .idle
        seenIP = nil
        seenCountry = ""
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
        let version = loadedDraft  // the draft being saved, fixed now: "Load" may change loadedDraft meanwhile
        let snapshot = config
        Task {
            saveError = await model.apply(snapshot, passwordless: passwordless)
            saving = false
            saved = saveError == nil
            if saved, version != nil {  // that draft is now the real config; a newer one stays
                removeDraft(ifStill: version)
                if loadedDraft == version { loadedDraft = nil }
            }
        }
    }
}

enum LeakResult {
    case pass, fail, incomplete, baseline, didNotRun

    init(output: String) {
        let result = output.split(whereSeparator: { $0.isNewline })
            .last { $0.hasPrefix("RESULT=") }
            .map { String($0.dropFirst(7)) }
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
