import Darwin
import Foundation
import SystemConfiguration

struct TunInterface: Hashable, Identifiable {
    let name: String
    let address: String
    let mask: String  // as ifconfig prints it, e.g. 0xfffffffc
    var id: String { name }
    var prefix: Int { Int(UInt32(mask.dropFirst(2), radix: 16)?.nonzeroBitCount ?? 0) }
}

private func walkInterfaces(_ body: (ifaddrs) -> Void) {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return }
    defer { freeifaddrs(head) }
    var cursor = head
    while let item = cursor {
        body(item.pointee)
        cursor = item.pointee.ifa_next
    }
}

private func ipv4String(_ sa: UnsafeMutablePointer<sockaddr>) -> (String, UInt32) {
    var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
    return (String(cString: buf), UInt32(bigEndian: sin.sin_addr.s_addr))
}

/// utun interfaces that carry an IPv4 address: candidates for TUN_ADDR.
func tunInterfaces() -> [TunInterface] {
    var result: [TunInterface] = []
    walkInterfaces { ifa in
        let name = String(cString: ifa.ifa_name)
        guard name.hasPrefix("utun"), let addr = ifa.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET), let netmask = ifa.ifa_netmask else { return }
        let ip = ipv4String(addr).0
        let mask = ipv4String(netmask).1
        result.append(TunInterface(name: name, address: ip, mask: String(format: "0x%08x", mask)))
    }
    return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// Byte counters of one interface. The kernel keeps them as 32 bit.
func interfaceBytes(_ name: String) -> (rx: UInt32, tx: UInt32)? {
    var found: (UInt32, UInt32)?
    walkInterfaces { ifa in
        guard found == nil, String(cString: ifa.ifa_name) == name, let addr = ifa.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data else { return }
        let d = data.assumingMemoryBound(to: if_data.self).pointee
        found = (d.ifi_ibytes, d.ifi_obytes)
    }
    return found
}

func primaryInterface() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "tunlock" as CFString, nil, nil),
          let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    else { return nil }
    return value["PrimaryInterface"] as? String
}

/// Samples an interface once per call: rates, and bytes moved since last call.
struct RateMeter {
    private var last: (name: String, rx: UInt32, tx: UInt32, at: Date)?

    mutating func sample(_ name: String?) -> (down: Double, up: Double, dDown: Double, dUp: Double)? {
        guard let name, let now = interfaceBytes(name) else { last = nil; return nil }
        defer { last = (name, now.rx, now.tx, Date()) }
        guard let prev = last, prev.name == name else { return (0, 0, 0, 0) }
        let dt = max(Date().timeIntervalSince(prev.at), 0.1)
        let down = Double(now.rx &- prev.rx), up = Double(now.tx &- prev.tx)
        return (down / dt, up / dt, down, up)
    }
}

func formatBytes(_ bytes: Double) -> String {
    let units = isRussian ? ["Б", "КБ", "МБ", "ГБ", "ТБ"] : ["B", "KB", "MB", "GB", "TB"]
    var value = max(bytes, 0)
    var unit = 0
    while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
    let number = unit == 0 || value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    return number + " " + units[unit]
}

func flagEmoji(_ code: String) -> String {
    guard code.count == 2 else { return "" }
    return code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }.map(String.init).joined()
}

func countryName(_ code: String) -> String {
    Locale(identifier: isRussian ? "ru" : "en").localizedString(forRegionCode: code) ?? code
}

func formatRate(_ bytesPerSecond: Double) -> String {
    let units = isRussian ? ["Б/с", "КБ/с", "МБ/с", "ГБ/с"] : ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = max(bytesPerSecond, 0)
    var unit = 0
    while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
    let number = unit == 0 || value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    return number + " " + units[unit]
}

/// The network of the current Wi-Fi/Ethernet connection, e.g. 192.168.0.0/24.
func currentLocalNetwork() -> String? {
    var result: String?
    walkInterfaces { ifa in
        let name = String(cString: ifa.ifa_name)
        guard result == nil, name.hasPrefix("en"), let addr = ifa.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_INET), let netmask = ifa.ifa_netmask else { return }
        let ip = ipv4String(addr).1
        let mask = ipv4String(netmask).1
        let net = ip & mask
        let bits = mask.nonzeroBitCount
        guard bits >= 8 else { return }
        result = "\(net >> 24).\((net >> 16) & 255).\((net >> 8) & 255).\(net & 255)/\(bits)"
    }
    return result
}

func isCIDR(_ s: String) -> Bool {
    let parts = s.split(separator: "/")
    guard parts.count == 2, let bits = Int(parts[1]), (8...32).contains(bits) else { return false }
    let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
}
