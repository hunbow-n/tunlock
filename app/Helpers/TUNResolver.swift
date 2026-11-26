import Darwin
import Foundation
import SystemConfiguration

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("tunlock-tun-dns: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("expected a TUN address and sing-box command") }

var address = in_addr()
guard inet_pton(AF_INET, args[1], &address) == 1 else { fail("invalid TUN IPv4 address") }
let tunAddress = UInt32(bigEndian: address.s_addr)
guard tunAddress < UInt32.max else { fail("cannot derive the TUN DNS address") }
// This is the address sing-box derives for the first IPv4 TUN address.
let next = tunAddress + 1
let resolver = [24, 16, 8, 0].map { String((next >> $0) & 255) }.joined(separator: ".")

guard let store = SCDynamicStoreCreate(nil, "Tunlock built-in DNS" as CFString, nil, nil) else {
    fail("could not connect to SystemConfiguration (\(SCError()))")
}

let key = "State:/Network/Service/com.tunlock.builtin/DNS" as CFString
let settings: [String: Any] = [
    kSCPropNetDNSServerAddresses as String: [resolver],
    kSCPropNetDNSSupplementalMatchDomains as String: [""],
    kSCPropNetDNSSupplementalMatchOrders as String: [1],
    "SupplementalMatchDomainsNoSearch": 1,
]
guard SCDynamicStoreAddTemporaryValue(store, key, settings as CFDictionary) else {
    fail("could not register the temporary DNS resolver (\(SCError()))")
}
// The store entry belongs to this process and disappears even if launchd kills it.
let child = Process()
child.executableURL = URL(fileURLWithPath: args[2])
child.arguments = Array(args.dropFirst(3))
do {
    try child.run()
} catch {
    fail("could not start sing-box: \(error.localizedDescription)")
}

let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
        if child.isRunning { child.terminate() }
    }
    source.resume()
    return source
}
withExtendedLifetime((store, signals)) {
    print("tunlock-tun-dns: registered a temporary system DNS resolver")
    child.waitUntilExit()
}
exit(child.terminationReason == .exit ? child.terminationStatus : 128 + child.terminationStatus)
