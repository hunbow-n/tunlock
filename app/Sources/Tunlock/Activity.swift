import SwiftUI
import UserNotifications

/// One guard log line, said in plain words.
struct LogEvent: Identifiable {
    let id: Int
    let time: String
    let icon: String
    let color: Color
    let text: String
    let raw: String
}

/// Reads the tail of the guard's log and keeps the lines a person cares about.
func readGuardLog(limit: Int = 300) -> [LogEvent]? {
    guard let handle = FileHandle(forReadingAtPath: Paths.guardLog) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
    let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    let today = DateFormatter.logDay.string(from: Date())
    var events: [LogEvent] = []
    for (i, line) in text.split(separator: "\n").suffix(limit).enumerated() {
        if let e = describeLogLine(String(line), id: i, today: today) { events.append(e) }
    }
    return events.reversed()
}

private extension DateFormatter {
    static let logDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// "2026-11-21 15:02:03 egress verified: 203.0.113.10 (NL) via utun6" -> a friendly event.
func describeLogLine(_ line: String, id: Int, today: String) -> LogEvent? {
    let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count == 3, parts[0].count == 10 else { return nil }
    let day = parts[0], clock = String(parts[1].prefix(5)), msg = parts[2]
    let time = day == today ? clock : "\(day.suffix(5).replacingOccurrences(of: "-", with: ".")) \(clock)"
    func ev(_ icon: String, _ color: Color, _ text: String) -> LogEvent {
        LogEvent(id: id, time: time, icon: icon, color: color, text: text, raw: msg)
    }
    func ipCountry(after prefix: String) -> String {
        guard let r = msg.range(of: prefix) else { return "" }
        let rest = msg[r.upperBound...].split(separator: " ").map(String.init)
        guard let ip = rest.first?.trimmingCharacters(in: CharacterSet(charactersIn: ",")) else { return "" }
        if rest.count > 1, rest[1].hasPrefix("("), rest[1].count >= 4 {
            let cc = String(rest[1].dropFirst().prefix(2))
            return "\(ip) \(flagEmoji(cc))"
        }
        return ip
    }

    switch true {
    case msg.hasPrefix("egress verified"):
        return ev("checkmark.shield.fill", .green, L("Exit verified: ", "Выход подтверждён: ") + ipCountry(after: "verified: "))
    case msg.hasPrefix("egress MISMATCH"):
        return ev("xmark.shield.fill", .red, L("Foreign exit ", "Чужой выход ") + ipCountry(after: "got ") + L(": internet closed", ": интернет закрыт"))
    case msg.hasPrefix("egress check got no answer"):
        return ev("exclamationmark.triangle.fill", .orange, L("Exit check got no answer: internet closed", "Проверка выхода без ответа: интернет закрыт"))
    case msg.hasPrefix("egress check expired"):
        return ev("clock.badge.exclamationmark", .orange, L("Exit not confirmed for too long: internet closed", "Выход давно не подтверждался: интернет закрыт"))
    case msg.hasPrefix("ssh forward down"):
        return ev("cable.connector.slash", .orange, L("SSH dropped: internet closed", "SSH отвалился: интернет закрыт"))
    case msg.hasPrefix("woke after"):
        return ev("moon.zzz.fill", .secondary, L("Mac woke up: checking the exit again", "Mac проснулся: проверяю выход заново"))
    case msg.hasPrefix("tun:") && msg.hasSuffix("gone"):
        return ev("bolt.horizontal.circle", .orange, L("TUN app disconnected: internet closed", "TUN-приложение отключилось: интернет закрыт"))
    case msg.hasPrefix("tun:"):
        return ev("arrow.triangle.2.circlepath", .secondary, L("TUN interface: ", "TUN-интерфейс: ") + (msg.split(separator: " ").last.map(String.init) ?? ""))
    case msg.hasPrefix("pf: FAILED"), msg.hasPrefix("pf refuses"):
        return ev("exclamationmark.octagon.fill", .red, L("Firewall rejected the rules", "Файрвол отклонил правила"))
    case msg.hasPrefix("pf: emergency"):
        return ev("exclamationmark.octagon.fill", .red, L("Emergency block loaded", "Включена аварийная блокировка"))
    case msg.hasPrefix("protected mode armed"):
        return ev("lock.shield", .green, L("Tunlock turned on", "Tunlock включён"))
    case msg.hasPrefix("direct mode: rules removed"):
        return ev("lock.open", .secondary, L("Tunlock turned off", "Tunlock выключен"))
    case msg.hasPrefix("direct mode: FAILED"):
        return ev("exclamationmark.octagon.fill", .red, L("Could not remove the rules", "Не удалось снять правила"))
    case msg.hasPrefix("guard") && msg.contains("started"):
        return ev("power", .secondary, L("Background service started", "Фоновая служба запущена"))
    case msg.hasPrefix("exception"), msg.hasPrefix("dns:"):
        return ev("arrow.uturn.right", .secondary, msg)
    case msg.hasPrefix("pf: phase"), msg.hasPrefix("pf enabled"), msg.hasPrefix("guard stopped"):
        return nil  // internal steps; the events above already tell the story
    default:
        return ev("info.circle", .secondary, msg)
    }
}

struct ActivityView: View {
    @EnvironmentObject var model: StatusModel
    @State private var events: [LogEvent]? = readGuardLog()
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("What the background service did", "Что делала фоновая служба")).font(.headline)
                Spacer()
                Button(L("Leak test", "Тест утечек")) { model.runLeakTest() }
                    .disabled(model.busy != nil || !model.installed)
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: Paths.guardLog))
                } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .help(L("Open the full log", "Открыть полный журнал"))
            }
            if let events, !events.isEmpty {
                List(events) { e in
                    HStack(spacing: 10) {
                        Image(systemName: e.icon).foregroundStyle(e.color).frame(width: 18)
                        Text(e.text).lineLimit(2)
                        Spacer()
                        Text(e.time).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .help(e.raw)
                }
                .listStyle(.inset)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(L("No events yet", "Событий пока нет")).foregroundStyle(.secondary)
                    Text(Paths.guardLog).font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .onReceive(timer) { _ in events = readGuardLog() }
    }
}

/// macOS notifications for state changes the user did not cause.
enum Notifier {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "notify") as? Bool ?? true }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
