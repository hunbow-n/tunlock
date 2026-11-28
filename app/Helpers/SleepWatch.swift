// tunlock-sleepwatch: run by the guard (as root). When the Mac is about to
// sleep it writes RUN_DIR/sleep-request and holds the sleep (up to 5 s) until
// the guard answers with RUN_DIR/sleep-ack, i.e. the tunnel is closed. On wake
// it removes the request; the guard reopens only after a fresh exit check.
// Waking on another network, the TUN app may reconnect anywhere: nothing may
// flow through it before that check.
import Foundation
import IOKit
import IOKit.pwr_mgt

// IOKit message ids (macros, not imported into Swift).
let kCanSystemSleep: UInt32 = 0xE000_0270
let kSystemWillSleep: UInt32 = 0xE000_0280
let kSystemHasPoweredOn: UInt32 = 0xE000_0300

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: tunlock-sleepwatch RUN_DIR\n".data(using: .utf8)!)
    exit(2)
}
let runDir = CommandLine.arguments[1]
let request = runDir + "/sleep-request"
let ack = runDir + "/sleep-ack"
var rootPort: io_connect_t = 0

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(f.string(from: Date())) sleepwatch: \(s)")
    fflush(stdout)
}

// What the guard last wrote to its state: the phase pf took and the exit check.
func lastConfirmed() -> String {
    let lines = (try? String(contentsOfFile: runDir + "/state", encoding: .utf8))?.split(separator: "\n") ?? []
    func value(_ key: String) -> String {
        lines.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } ?? "unknown"
    }
    return "phase \(value("phase")), exit check \(value("egress_check"))"
}

let callback: IOServiceInterestCallback = { _, _, messageType, argument in
    switch messageType {
    case kCanSystemSleep:
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case kSystemWillSleep:
        try? FileManager.default.removeItem(atPath: ack)
        let start = Date()
        FileManager.default.createFile(atPath: request, contents: Data("\(start.timeIntervalSince1970)\n".utf8))
        log("sleep requested, waiting for the guard to close the tunnel")
        let deadline = start.addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ack), Date() < deadline { usleep(100_000) }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if let phase = try? String(contentsOfFile: ack, encoding: .utf8) {
            log("guard confirmed pf phase \(phase.trimmingCharacters(in: .whitespacesAndNewlines)) in \(ms) ms, sleeping")
        } else {
            log("no confirmation from the guard in \(ms) ms (last confirmed: \(lastConfirmed())), sleeping anyway")
        }
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case kSystemHasPoweredOn:
        try? FileManager.default.removeItem(atPath: request)
        try? FileManager.default.removeItem(atPath: ack)
        log("woke up: the guard checks the exit before reopening")
    default:
        break
    }
}

var notifyPort: IONotificationPortRef?
var notifier: io_object_t = 0
rootPort = IORegisterForSystemPower(nil, &notifyPort, callback, &notifier)
guard rootPort != 0, let port = notifyPort else {
    log("cannot register for sleep notifications")
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
log("watching sleep for \(runDir)")
CFRunLoopRun()
