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

let callback: IOServiceInterestCallback = { _, _, messageType, argument in
    switch messageType {
    case kCanSystemSleep:
        IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case kSystemWillSleep:
        try? FileManager.default.removeItem(atPath: ack)
        FileManager.default.createFile(atPath: request, contents: Data("\(Date().timeIntervalSince1970)\n".utf8))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ack), Date() < deadline { usleep(100_000) }
        log(FileManager.default.fileExists(atPath: ack) ? "tunnel closed, sleeping" : "no answer from the guard in 5 s, sleeping anyway")
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
