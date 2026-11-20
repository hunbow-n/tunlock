#!/bin/bash
# Real pf on a throwaway macOS CI machine: loads tunlock's rules into the live
# firewall and proves what they do with real packets. Refuses to run anywhere
# but GitHub Actions: on a workstation it would cut the network.
#   CI:  sudo env TUNLOCK_PF_LIVE=1 GITHUB_ACTIONS=true bash tests/pf-live.sh
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd "$(dirname "$0")/.." || exit 1
if [[ ${GITHUB_ACTIONS:-} != true || ${TUNLOCK_PF_LIVE:-} != 1 || $EUID != 0 ]]; then
  echo "pf-live: CI only (GitHub Actions, root, TUNLOCK_PF_LIVE=1). It would cut this machine's network." >&2
  exit 2
fi

ANCHOR=com.apple/000.tunlock
ROGUE=com.apple/000.aaa          # sorts before ours: stands in for another kill switch
ALLOWED=1.0.0.1                  # plays the proxy: the only host allowed outside the tunnel
BLOCKED=1.1.1.1
T=bin/tunlock
CONF=$(mktemp)
printf 'UPSTREAM=proxy\nPROXY_HOST=%s\nPROXY_PORT=443\nTUN_ADDR=10.200.0.1\nTUN_MASK=0xfffffffc\n' "$ALLOWED" > "$CONF"
TOKEN=''
pass=0 fail=0 skip=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
ko() { fail=$((fail + 1)); echo "FAIL $1"; }
sk() { skip=$((skip + 1)); echo "SKIP $1"; }
https() { curl -4 -sS -o /dev/null --connect-timeout 3 --max-time 5 "https://$1/cdn-cgi/trace" >/dev/null 2>&1; }
udp_dns() { # a raw DNS query for example.com; true if any answer comes back
  [[ $(printf '%b' '\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01' \
    | nc -u -w 3 "$1" 53 2>/dev/null | wc -c) -gt 0 ]]
}
# Stops our own guard only (by PID, never by name) and waits until it is gone,
# so it cannot load rules again after cleanup.
stop_guard() {
  [[ -n ${GUARD:-} ]] || return 0
  kill "$GUARD" 2>/dev/null
  local i
  for (( i = 0; i < 20; i++ )); do kill -0 "$GUARD" 2>/dev/null || break; sleep 0.25; done
  kill -9 "$GUARD" 2>/dev/null
  wait "$GUARD" 2>/dev/null
  GUARD=''
}
cleanup() {
  stop_guard
  [[ -z ${UTUN:-} ]] || kill "$UTUN" 2>/dev/null
  [[ -s ${GD:-/nonexistent}/run/token ]] && pfctl -X "$(cat "$GD/run/token")" >/dev/null 2>&1
  pfctl -a "$ROGUE" -F rules >/dev/null 2>&1
  pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1
  [[ -z $TOKEN ]] || pfctl -X "$TOKEN" >/dev/null 2>&1
  [[ -z ${WEB:-} ]] || kill "$WEB" 2>/dev/null
  rm -f "$CONF"
}
trap cleanup EXIT

echo "== baseline (no tunlock rules)"
if ! https "$BLOCKED" || ! https "$ALLOWED"; then
  # Without a working baseline nothing below would prove anything: fail loudly.
  echo "FAIL baseline: this runner has no direct HTTPS to $BLOCKED/$ALLOWED" >&2
  exit 1
fi
has6=0; curl -6 -sS -o /dev/null --connect-timeout 3 --max-time 5 'https://[2606:4700:4700::1111]/' 2>/dev/null && has6=1
hasudp=0; udp_dns 8.8.8.8 && hasudp=1
echo "baseline: IPv4 ok, IPv6=$has6, UDP DNS=$hasudp"
pfctl -sr 2>/dev/null | grep -qF 'anchor "com.apple/*"' || pfctl -f /etc/pf.conf 2>/dev/null

python3 -m http.server 18080 --bind 127.0.0.1 >/dev/null 2>&1 & WEB=$!
sleep 1

echo "== tunlock block phase loaded into the real pf"
TUNLOCK_CONF=$CONF $T render-rules block "" | pfctl -a "$ANCHOR" -f - 2>&1 | grep -v ALTQ
TOKEN=$(pfctl -E 2>&1 | awk '/Token/ { print $NF }')
pfctl -a "$ANCHOR" -sr | grep -q 'label "tunlock-' && ok "pf holds the labelled rule set" || ko "pf holds the labelled rule set"
https "$BLOCKED" && ko "direct IPv4 to $BLOCKED is blocked" || ok "direct IPv4 to $BLOCKED is blocked"
https "$ALLOWED" && ok "the allowed entry $ALLOWED:443 still works" || ko "the allowed entry $ALLOWED:443 still works"
if (( hasudp )); then udp_dns 8.8.8.8 && ko "UDP DNS to 8.8.8.8 is blocked" || ok "UDP DNS to 8.8.8.8 is blocked"
else sk "UDP DNS: not reachable even without tunlock"; fi
if (( has6 )); then
  curl -6 -sS -o /dev/null --connect-timeout 3 --max-time 5 'https://[2606:4700:4700::1111]/' 2>/dev/null \
    && ko "IPv6 is blocked" || ok "IPv6 is blocked"
else sk "IPv6: not available on this runner"; fi
curl -s -o /dev/null --max-time 3 http://127.0.0.1:18080/ && ok "loopback still works" || ko "loopback still works"
c=$(TUNLOCK_CONF=$CONF $T conflicts 2>&1)
[[ $c == none ]] && ok "no conflicts on the stock layout" || ko "no conflicts on the stock layout ($c)"

echo "== another kill switch's quick rule sorts before ours"
echo 'pass out quick all' | pfctl -a "$ROGUE" -f - 2>&1 | grep -v ALTQ
https "$BLOCKED" && ok "the rogue rule really opens a leak (why detection matters)" \
  || ko "the rogue rule really opens a leak (why detection matters)"
c=$(TUNLOCK_CONF=$CONF $T conflicts 2>&1)
grep -q "$ROGUE" <<< "$c" && ok "tunlock reports the conflict" || ko "tunlock reports the conflict ($c)"
pfctl -a "$ROGUE" -F rules >/dev/null 2>&1
https "$BLOCKED" && ko "blocked again once the rogue rule is gone" || ok "blocked again once the rogue rule is gone"

echo "== removing tunlock's rules restores the network"
pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1
pfctl -a "$ANCHOR" -sr | grep -q tunlock && ko "anchor is empty" || ok "anchor is empty"
https "$BLOCKED" && ok "direct IPv4 works again" || ko "direct IPv4 works again"

echo "== the real guard on the real pf"
# Proxy mode, so no SSH is involved. The guard resets pf states when it arms:
# the runner's own connections drop for a moment and reconnect after cleanup.
GD=$(mktemp -d)
mkdir -p "$GD/db" "$GD/run" "$GD/resolver"
echo protected > "$GD/db/mode"
cp "$CONF" "$GD/conf"; echo PROBE_INTERVAL=5 >> "$GD/conf"
gstate() { awk -F= -v k="$1" '$1 == k { print $2 }' "$GD/run/state" 2>/dev/null; }
wait_phase() { local i; for (( i = 0; i < ${2:-15}; i++ )); do [[ $(gstate phase) == "$1" ]] && return 0; sleep 1; done; return 1; }
# Started directly (no wrapper function): $! is then the guard itself, since
# env execs bash in place, and cleanup kills the right process.
env TUNLOCK_CONF="$GD/conf" TUNLOCK_STATE_DIR="$GD/db" TUNLOCK_RUN_DIR="$GD/run" TUNLOCK_RESOLVER_DIR="$GD/resolver" \
  bash "$T" guard > "$GD/guard.log" 2>&1 &
GUARD=$!

wait_phase block && ok "guard: no TUN interface -> block" || ko "guard: no TUN interface -> block (phase $(gstate phase))"
https "$BLOCKED" && ko "guard block: direct IPv4 blocked" || ok "guard block: direct IPv4 blocked"
https "$ALLOWED" && ok "guard block: the proxy is still reachable" || ko "guard block: the proxy is still reachable"
pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1
sleep 5
pfctl -a "$ANCHOR" -sr | grep -q 'label "tunlock-' && ok "guard restores rules flushed behind its back" \
  || ko "guard restores rules flushed behind its back"

python3 tests/utun.py 60 > "$GD/utun" & UTUN=$!
sleep 2
U=$(head -1 "$GD/utun")
if [[ $U =~ ^utun[0-9]+$ ]] && ifconfig "$U" inet 10.200.0.1 10.200.0.1 netmask 0xfffffffc up; then
  wait_phase probe && ok "guard: TUN up, exit unverified -> probe on $U" || ko "guard: TUN up -> probe (phase $(gstate phase))"
  https "$BLOCKED" && ko "guard probe: direct IPv4 still blocked" || ok "guard probe: direct IPv4 still blocked"
  [[ $(gstate egress_ok) == 0 ]] && ok "guard probe: an exit that does not answer never opens" \
    || ko "guard probe: an exit that does not answer never opens"
  kill "$UTUN" 2>/dev/null; UTUN=''
  wait_phase block && ok "guard: TUN gone -> block" || ko "guard: TUN gone -> block (phase $(gstate phase))"
else
  ko "could not create a utun interface for the guard test"
fi
GPID=$GUARD
stop_guard
kill -0 "$GPID" 2>/dev/null && ko "the guard is stopped after the test" || ok "the guard is stopped after the test"
echo "-- guard log"; cat "$GD/guard.log"

echo "$pass passed, $fail failed, $skip skipped"
(( fail == 0 ))
