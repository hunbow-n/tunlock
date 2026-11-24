# Acceptance tests

Unit and guard tests (`tests/run.sh`, never with sudo: it refuses root) cover
config parsing, rule generation and the guard against stubbed system tools.
`sudo tests/pf-syntax.sh` asks pfctl to parse, never load, every rule set. They prove
nothing about leaks. Leak results come only from a real Mac on real networks.
Record the macOS version, the network and the output of each run.

`sudo tunlock test` prints one line per check: PASS (behaved as required),
FAIL (leak or broken tunnel), SKIP (could not be checked on this network, with
the reason) or INFO (direct mode, reference only). The last line is
`RESULT=pass|fail|incomplete|baseline`. A required check that could not run
gives `incomplete`, never `pass`.

No answer on the physical link proves blocking only when the target is known
to answer. Otherwise the check is a SKIP, not a PASS:

- IPv4: 1.1.1.1 must answer through the tunnel in the same run.
- UDP: 1.1.1.1 must answer DNS through the tunnel as itself. Its
  `whoami.cloudflare` answer must name the verified exit, so a TUN app that
  answers DNS on its own does not count.
- IPv6: the tunnel usually has no IPv6, so the control is a direct reference run
  (`tunlock off`, then `sudo tunlock test`) on the same network within the last
  day. The network is the interface, the IPv6 router with its link-layer address,
  and the interface's /64 prefix; without the router's address or a prefix there
  is no reference. It is saved in `/var/db/tunlock/ipv6-baseline`.

Protected runs print `UNCONFIRMED=` with what this run could not prove blocked
(`ipv4`, `udp`, `ipv6`, or nothing). `RESULT=pass` with `UNCONFIRMED=ipv6` means
no leak was seen, but IPv6 blocking is not proven on this network.

| check | protected |
|---|---|
| pf enabled and the anchor holds a tunlock-labelled set | must pass |
| HTTPS by IP through `TUN_ADDR` returns `EXPECTED_EGRESS` | must pass |
| HTTPS by name, system DNS and default route, returns `EXPECTED_EGRESS` | must pass |
| direct IPv4 TCP on the physical interface, no DNS | must be blocked; SKIP (incomplete) if 1.1.1.1 does not answer through the tunnel either |
| direct UDP DNS query to 1.1.1.1 on the physical interface | must be blocked; SKIP if 1.1.1.1 does not answer through the tunnel as itself |
| direct IPv6, and IPv6 over the default route | must be blocked; SKIP without IPv6 on the network, or without a direct reference run on this network in the last day that saw IPv6 answer |

Run the protected test with no other kill switch active. Another pf anchor
evaluated earlier would decide first and hide what tunlock does.

## Runs

1. **Baseline.** Close AI clients, run `tunlock direct`, then `sudo tunlock test`.
   It notes whether IPv6 works on this network and saves that as the IPv6
   reference for protected runs here.
2. **Protected.** Run `tunlock protect`, then `sudo tunlock test`. All checks
   must pass.
3. **SSH stopped.** Stop the keeper so launchd does not restart it. The test
   runs only after the forward is confirmed down:
   ```bash
   port=$(/usr/local/bin/tunlock config | awk -F= '$1 == "HEALTH_PORT" { print $2 }')
   launchctl bootout "gui/$(id -u)/tunlock.ssh"
   for _ in 1 2 3 4 5; do nc -z -G1 127.0.0.1 "$port" 2>/dev/null || break; sleep 1; done
   if nc -z -G1 127.0.0.1 "$port" 2>/dev/null; then
     echo "forward on port $port is still up: not testing"
   else
     sudo /usr/local/bin/tunlock test
   fi
   launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/tunlock.ssh.plist
   ```
   While SSH is down, the tunnel lines FAIL (expected) and every direct line
   must PASS. After the restart, status returns to `PROTECTED`.
4. **Server unreachable.** Block the server from another device, or stop sshd
   on it. Direct paths must fail.
5. **TUN client disconnected**, then **quit** (Cmd+Q). Run `tunlock status`; it
   must show `BLOCKED` with `Reason no_tun`. Direct paths must fail.
6. **Reconnect.** Start the TUN client again, ideally until it gets a different
   utun number. Within a few seconds, status returns to `PROTECTED` with the new
   utun. While it reconnects, `while :; do curl -4s --interface en0
   --max-time 1 https://1.1.1.1 -o /dev/null && echo LEAK; sleep 0.2; done`
   must print nothing.
7. **IPv6 network.** On a network where step 1 showed working IPv6, repeat
   step 2. The IPv6 checks must fail.
8. **Sleep.** With the loop from step 6 running, close the lid for at least a
   minute, then open it. The loop prints nothing, and status returns to
   `PROTECTED` or stays `BLOCKED`.
9. **Wi-Fi change.** Switch to another network or a phone hotspot, with the
   same loop running.
10. **Reboot in protected mode.** After login, `tunlock status` must show
    `BLOCKED` until the tunnel is verified, never `DIRECT`. With `TUN_SERVICE`
    set, the guard starts the client itself once the forward is up and the
    rules are confirmed; otherwise start it yourself. Then wait for `PROTECTED`.
11. **Direct mode and uninstall.** `tunlock direct` must restore normal
    internet immediately. `sudo ./uninstall.sh` must leave
    `sudo pfctl -a com.apple/000.tunlock -sr` empty and the internet working.
