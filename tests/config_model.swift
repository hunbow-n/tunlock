// Tests TunConfig (the app's model of tunlock.conf) without any UI.
// Built with app/Sources/Tunlock/{Backend,L10n,Net}.swift by tests/swift-model.sh.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print((ok ? "ok   " : "FAIL ") + "swift: " + name)
    if !ok { failures += 1 }
}

@main
enum ConfigModelTests {
    static func main() {
        var c = TunConfig()
        c.vpsIP = "203.0.113.10"; c.tunAddr = "10.20.0.1"; c.tunMask = "0xfffffffc"
        c.exitMode = .both
        check("'IP and country' stays chosen while the country is empty", c.exitMode == .both)
        c.expectedCountry = "nl"
        check("both: right IP + country matches", c.exitMatches(ip: "203.0.113.10", country: "NL"))
        check("both: right IP, wrong country fails", !c.exitMatches(ip: "203.0.113.10", country: "DE"))
        check("both: writes the country", c.render().contains("EXPECTED_COUNTRY=NL"))

        c.exitMode = .ip
        check("ip: a stale country is not written", !c.render().contains("EXPECTED_COUNTRY"))
        check("ip: country ignored", c.exitMatches(ip: "203.0.113.10", country: ""))

        c.exitMode = .country
        check("country: writes EXPECTED_EGRESS=any", c.render().contains("EXPECTED_EGRESS=any"))
        check("country: any IP in the country matches", c.exitMatches(ip: "192.0.2.5", country: "NL"))
        check("country: other country fails", !c.exitMatches(ip: "192.0.2.5", country: "US"))

        let back = TunConfig.parse(c.render())
        check("round trip keeps the country mode", back.exitMode == .country && back.expectedCountry == "NL")
        c.exitMode = .both; c.expectedEgress = "203.0.113.10"
        let both = TunConfig.parse(c.render())
        check("round trip keeps 'IP and country'", both.exitMode == .both && both.effectiveEgress == "203.0.113.10")

        var p = TunConfig()
        p.upstream = "proxy"; p.proxyHost = "198.51.100.20"; p.proxyPort = "8080"; p.tunAddr = "10.20.0.1"
        let pr = p.render()
        check("proxy: no SSH keys written", !pr.contains("SSH_") && pr.contains("UPSTREAM=proxy"))
        check("proxy: exit defaults to the proxy IP", p.exitMatches(ip: "198.51.100.20", country: ""))
        var r = TunConfig()
        r.upstream = "proxy"; r.proxyHost = "198.51.100.20"; r.tunAddr = "10.20.0.1"
        r.expectedEgress = " 162.210.67.182\n"  // pasted with a space and a newline (seen in the wild)
        check("a pasted exit IP with whitespace still matches", r.exitMatches(ip: "162.210.67.182", country: "US"))
        check("and is saved clean", r.render().contains("EXPECTED_EGRESS=162.210.67.182\n"))
        check("garbage in the field is not taken for an IPv4", !looksLikeIPv4("162.210.67.182\n162.210.67.182"))

        var x = TunConfig.parse("VPS_IP=203.0.113.10\nSSH_HOST=198.51.100.9\nPROBE_URL=https://1.0.0.1/cdn-cgi/trace\nTUN_ADDR=10.20.0.1\n")
        x.sshUser = "me"
        let xr = x.render()
        check("keys the form has no field for are kept on save", xr.contains("SSH_HOST=\"198.51.100.9\"") && xr.contains("PROBE_URL=\"https://1.0.0.1/cdn-cgi/trace\""))
        exit(failures == 0 ? 0 : 1)
    }
}
