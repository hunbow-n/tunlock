#!/bin/bash
# shellcheck disable=SC2016  # test hooks are written with literal $STUB
# Unit and guard tests: no root, no network, no changes to the system.
# The guard runs against stubs of pfctl, route, curl, nc and netstat.
# With sudo, also asks pfctl to parse (not load) every generated ruleset.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
exec < /dev/null  # nothing here reads input: a stub that tries fails fast instead of hanging
# Never as root: stubs are disabled for root, so the guard tests below would
# drive the real pfctl and route. Syntax checks live in tests/pf-syntax.sh.
if [[ $EUID == 0 ]]; then echo "Do not run tests/run.sh as root. For pf syntax: sudo tests/pf-syntax.sh" >&2; exit 1; fi
T=bin/tunlock
F=tests/fixtures
export TUNLOCK_CONF=$F/good.conf
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
ko() { fail=$((fail + 1)); echo "FAIL $1"; [[ -z ${2:-} ]] || printf "     %s\n" "$2"; }
expect_eq() { if [[ $2 == "$3" ]]; then ok "$1"; else ko "$1" "got: $2"$'\n'"want: $3"; fi; }
bad_conf() { # name, line to append or replace
  local tmp
  tmp=$(mktemp)
  grep -v "^${2%%=*}=" "$F/good.conf" > "$tmp"
  echo "$2" >> "$tmp"
  if out=$(TUNLOCK_CONF=$tmp $T render-rules block 2>&1); then ko "rejects $1" "$out"
  else ok "rejects $1: ${out#tunlock: }"; fi
  rm -f "$tmp"
}

if command -v shellcheck >/dev/null; then
  if out=$(shellcheck -s bash bin/tunlock install.sh uninstall.sh tests/run.sh tests/pf-syntax.sh tests/pf-live.sh tests/swift-model.sh tests/mcp.sh tests/stubs/* contrib/swiftbar/*.sh build-app.sh tools/snapshot.sh tools/release-key.sh 2>&1); then
    ok shellcheck; else ko shellcheck "$out"; fi
else echo "skip shellcheck (not installed)"; fi

expect_eq "open rules match golden file" "$($T render-rules open utun7 en0)" "$(cat $F/rules.open.utun7)"
blk=$($T render-rules block "" en0)
expect_eq "block phase ends with a full block" "$(tail -1 <<< "$blk" | cut -c1-31)" "block drop quick all label \"tun"
grep -q utun <<< "$blk" && ko "block phase has no tunnel pass" "$blk" || ok "block phase has no tunnel pass"
prb=$($T render-rules probe utun7)
expect_eq "probe phase: the probe plus the TUN stack's internal leg" \
  "$(grep -c 'on utun7' <<< "$prb") $(grep -c '1.1.1.1 port 443' <<< "$prb") $(grep -c '10.20.0.0/30 to 10.20.0.0/30' <<< "$prb")" "4 2 2"
for phase in block probe open; do
  r=$($T render-rules $phase utun7)
  grep -E '^pass' <<< "$r" | grep -Ev 'quick' && ko "$phase: every pass is quick" || ok "$phase: every pass is quick"
  grep -qE '^pass.*inet6' <<< "$r" && ko "$phase: no IPv6 pass" || ok "$phase: no IPv6 pass"
  # The AI networks are closed before the first pass that could reach them.
  expect_eq "$phase: AI networks closed before any pass but lo0" \
    "$(grep -vE '^#|on lo0' <<< "$r" | head -2 | awk '{ print $1, $NF }' | paste -sd' ' -)" "block 160.79.104.0/21 block 2607:6bc0::/32"
done
$T render-rules open en0 >/dev/null 2>&1 && ko "refuses non-utun interface" || ok "refuses non-utun interface"

cfg=$($T config)
expect_eq "health check uses the first forward" "$(grep -E '^HEALTH_(HOST|PORT)=' <<< "$cfg" | tr '\n' ' ')" \
  "HEALTH_HOST=127.0.0.1 HEALTH_PORT=10800 "
expect_eq "SSH_HOST and EXPECTED_EGRESS default to VPS_IP" \
  "$(grep -E '^(SSH_HOST|EXPECTED_EGRESS)=' <<< "$cfg" | tr '\n' ' ')" \
  "SSH_HOST=203.0.113.10 EXPECTED_EGRESS=203.0.113.10 "
expect_eq "probe IP read from PROBE_URL" "$(grep '^PROBE_IP=' <<< "$cfg")" "PROBE_IP=1.1.1.1"
expect_eq "finds utun by address and mask" \
  "$(TUNLOCK_TEST_IFCONFIG=$F/ifconfig.txt $T config | grep '^TUN_IFACE=')" "TUN_IFACE=utun7"
tmpc=$(mktemp); sed 's/^TUN_MASK=.*/TUN_MASK=0xffffff00/' "$F/good.conf" > "$tmpc"
expect_eq "wrong mask finds no utun" \
  "$(TUNLOCK_CONF=$tmpc TUNLOCK_TEST_IFCONFIG=$F/ifconfig.txt $T config | grep '^TUN_IFACE=')" "TUN_IFACE="
rm -f "$tmpc"

# Cascade: the entry is the only host reachable outside the tunnel.
tmpj=$(mktemp); cat "$F/good.conf" > "$tmpj"; printf 'JUMP_HOST=198.51.100.7\nJUMP_USER=relay\n' >> "$tmpj"
jr=$(TUNLOCK_CONF=$tmpj $T render-rules open utun7)
expect_eq "cascade: pf allows only the entry host" \
  "$(grep -c '198.51.100.7 port 22' <<< "$jr") $(grep -c '203.0.113.10' <<< "$jr")" "1 0"
expect_eq "cascade: entry and egress stay separate" \
  "$(TUNLOCK_CONF=$tmpj $T config | grep -E '^(ENTRY_HOST|EXPECTED_EGRESS|JUMP_PORT)=' | tr '\n' ' ')" \
  "JUMP_PORT=22 EXPECTED_EGRESS=203.0.113.10 ENTRY_HOST=198.51.100.7 "
rm -f "$tmpj"
bad_conf "a host name for JUMP_HOST" "JUMP_HOST=relay.example.com"
bad_conf "a key path with spaces" "SSH_IDENTITY=~/my keys/id"

# Exceptions: whole networks on any port, plus per-domain DNS.
tmpb=$(mktemp); cat "$F/good.conf" > "$tmpb"
printf 'BYPASS_NETS="192.168.0.0/24 10.10.0.0/16"\nBYPASS_DNS="corp.example=192.168.0.1 lab.example=172.16.5.2"\n' >> "$tmpb"
br=$(TUNLOCK_CONF=$tmpb $T render-rules block "" en0)
expect_eq "exceptions: whole networks pass in the block phase, any port" \
  "$(grep -c -e 'on en0 inet from any to 192.168.0.0/24 keep state (if-bound)$' -e 'on en0 inet from any to 10.10.0.0/16 keep state (if-bound)$' <<< "$br")" "2"
expect_eq "exceptions: DNS servers outside the networks pass on port 53 only" \
  "$(grep -c 'to 172.16.5.2 port 53' <<< "$br")" "1"
expect_eq "exceptions come before the final block" "$(tail -1 <<< "$br" | cut -c1-20)" "block drop quick all"
expect_eq "no exceptions without a physical interface" "$(TUNLOCK_CONF=$tmpb $T render-rules block "" "" | grep -c 192.168.0.0/24)" "0"
l1=$(TUNLOCK_CONF=$tmpb $T render-rules open utun6 en0 | tail -1); l2=$(TUNLOCK_CONF=$tmpb $T render-rules open utun7 en0 | tail -1)
[[ $l1 != "$l2" ]] && ok "rule sets get distinct labels" || ko "rule sets get distinct labels" "$l1"
rd=$(mktemp -d); printf 'nameserver 9.9.9.9\n' > "$rd/lab.example"
out=$(TUNLOCK_TEST_PATH=$PWD/tests/stubs TUNLOCK_CONF=$tmpb TUNLOCK_RESOLVER_DIR=$rd $T _sync-resolvers 2>/dev/null)
expect_eq "dns: writes a managed resolver" "$(tail -1 "$rd/corp.example")" "nameserver 192.168.0.1"
expect_eq "dns: leaves a foreign resolver alone and warns" \
  "$(cat "$rd/lab.example") | ${out##*warning=}" "nameserver 9.9.9.9 | $rd/lab.example exists and is not managed by tunlock"
sed -i '' '/^BYPASS_DNS/d' "$tmpb"
TUNLOCK_TEST_PATH=$PWD/tests/stubs TUNLOCK_CONF=$tmpb TUNLOCK_RESOLVER_DIR=$rd $T _sync-resolvers >/dev/null 2>&1
expect_eq "dns: removes its own resolver when dropped, keeps the foreign one" "$(ls "$rd")" "lab.example"
rm -rf "$tmpb" "$rd"
bad_conf "a network without a prefix" "BYPASS_NETS=192.168.0.0"
bad_conf "a too wide network" "BYPASS_NETS=0.0.0.0/0"
bad_conf "a DNS rule without a server" "BYPASS_DNS=corp.example"
bad_conf "a DNS rule with a path in the domain" "BYPASS_DNS=../../etc/x=192.168.0.1"

# ---- guard against stubbed pfctl/route/curl/nc (regressions from review)
STUBS=$PWD/tests/stubs
guard_setup() {
  STUB=$(mktemp -d); export STUB
  mkdir -p "$STUB/db" "$STUB/run" "$STUB/resolver"
  echo protected > "$STUB/db/mode"
  touch "$STUB/ssh_up"
  echo 203.0.113.10 > "$STUB/egress"
  echo "en0 192.168.1.1" > "$STUB/kernel_route"
  { cat "$F/good.conf"; echo 'BYPASS_NETS="192.168.0.0/24"'; echo PROBE_INTERVAL=5; } > "$STUB/conf"
  cp "$F/ifconfig.txt" "$STUB/ifconfig.txt"
}
gt() { # ticks [between-hook]
  TUNLOCK_TEST_PATH=$STUBS TUNLOCK_CONF=$STUB/conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run \
    TUNLOCK_RESOLVER_DIR=$STUB/resolver TUNLOCK_TEST_IFCONFIG=$STUB/ifconfig.txt TUNLOCK_TEST_BETWEEN=${2:-} \
    $T _guard-ticks "$1" > "$STUB/guard.log" 2>&1
}
st() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print }' "$STUB/run/state"; }
verdict() { TUNLOCK_CONF=$STUB/conf TUNLOCK_RUN_DIR=$STUB/run $T status --porcelain | awk -F= '$1 == "verdict" { print $2 }'; }
hook=$(mktemp); chmod +x "$hook"

guard_setup; gt 2
expect_eq "guard: verified tunnel opens" "$(st phase) $(st egress_ok) $(verdict) [$(st error)]" "open 1 protected []"
expect_eq "guard: egress country comes from the probe" "$(st egress_country)" "NL"
grep -q 'on utun7 inet from 10.20.0.1 to any' "$STUB/anchor" && grep -q 'label "tunlock-' "$STUB/anchor" \
  && ok "guard: open rules with label are in the anchor" || ko "guard: open rules with label are in the anchor" "$(cat "$STUB/anchor")"
expect_eq "guard: connections reset once after rules are in place" "$(wc -l < "$STUB/states.log" | tr -d ' ')" "1"
rm -rf "$STUB"

guard_setup; : > "$STUB/pf_fail"; gt 2
expect_eq "guard: rejected pf load is never reported as a phase" \
  "$(st phase)|$(verdict)|$([[ -e $STUB/states.log ]] && echo reset || echo none)" "failed|unprotected|none"
grep -q 'pf rejected' <<< "$(st error)" && ok "guard: rejected pf load shows an error" || ko "guard: rejected pf load shows an error" "$(st error)"
rm -rf "$STUB"

guard_setup; printf '#!/bin/bash\necho "phase=probe" > "$STUB/pf_fail"; rm -f "$STUB/ssh_up"\n' > "$hook"; gt 2 "$hook"
expect_eq "guard: rejected open -> probe falls back to the emergency block" \
  "$(verdict) | $(st phase) | $(grep -c 'label "tunlock-emergency"' "$STUB/anchor") $(grep -c 'to any no state' "$STUB/anchor")" \
  "unprotected | emergency | 1 0"
rm -rf "$STUB"

guard_setup; printf '#!/bin/bash\n: > "$STUB/pf_fail"; rm -f "$STUB/ssh_up"\n' > "$hook"; gt 2 "$hook"
expect_eq "guard: pf refusing every load takes the untrusted utun down" \
  "$(verdict) | $(st phase) | $(cat "$STUB/down.log" 2>/dev/null) | $(st error | grep -c 'taken down: utun7')" "unprotected | failed | utun7 | 1"
grep -q 'block drop quick all' "$STUB/anchor" && ok "guard: the old set's final block still stops direct traffic" \
  || ko "guard: the old set's final block still stops direct traffic" "$(cat "$STUB/anchor")"
rm -rf "$STUB"

guard_setup; printf '#!/bin/bash\n: > "$STUB/pf_fail"; sed -i "" s/utun7/utun8/ "$STUB/ifconfig.txt"\n' > "$hook"; gt 2 "$hook"
expect_eq "guard: a utun allowed by the loaded rules is taken down after a renumber" \
  "$(cat "$STUB/down.log" 2>/dev/null) | $(st tun)" "utun7 | utun8"
rm -rf "$STUB"

guard_setup; printf '#!/bin/bash\n: > "$STUB/pf_fail"; touch "$STUB/ifconfig_fail"; rm -f "$STUB/ssh_up"\n' > "$hook"; gt 2 "$hook"
expect_eq "guard: a failed ifconfig down is reported, not claimed" \
  "$(st error | grep -c 'could NOT confirm taken down: utun7') $(st error | grep -c '; taken down:')" "1 0"
rm -rf "$STUB"

guard_setup; printf '#!/bin/bash\nrm -f "$STUB/ssh_up"\n' > "$hook"; gt 2 "$hook"
expect_eq "guard: ssh down closes the tunnel until verified" "$(st phase) $(st egress_ok) $(verdict)" "probe 0 blocked"
rm -rf "$STUB"

guard_setup; printf '#!/bin/bash\n[[ $1 == 0 ]] && { rm -f "$STUB/egress"; sleep 6; }\nexit 0\n' > "$hook"; gt 2 "$hook"
expect_eq "guard: egress probe timeout closes the tunnel" "$(st phase) $(st egress_ok) $(verdict)" "probe 0 blocked"
rm -rf "$STUB"

guard_setup; touch "$STUB/states_fail"; gt 2
expect_eq "guard: failed connection reset is an error" "$(verdict) | $(st error)" "unprotected | could not reset existing connections"
expect_eq "guard: no open phase while old connections were not reset" "$(st phase) $(st egress_ok)" "probe 0"
rm -rf "$STUB"

guard_setup; echo "192.168.0.0/24 192.168.1.1" > "$STUB/run/routes"; echo "utun6 10.20.0.1" > "$STUB/kernel_route"; gt 1
expect_eq "routes: a recorded route that moved to the tunnel is restored" \
  "$(cat "$STUB/kernel_route") | $(grep -c '^add 192.168.0.0/24 192.168.1.1' "$STUB/route.log")" "en0 192.168.1.1 | 1"
grep -q 'on en0 inet from any to 192.168.0.0/24' "$STUB/anchor" \
  && ok "routes: exception rule is bound to the physical interface" || ko "routes: exception rule is bound to the physical interface" "$(cat "$STUB/anchor")"
rm -rf "$STUB"

guard_setup; sed -i '' '/^BYPASS_NETS/d' "$STUB/conf"; echo 'BYPASS_DNS="corp.example=172.16.5.2"' >> "$STUB/conf"
echo "utun6 10.20.0.1" > "$STUB/kernel_route"; gt 1
expect_eq "routes: a DNS server outside the exception networks gets a host route" \
  "$(grep -c '^add 172.16.5.2 192.168.1.1' "$STUB/route.log")" "1"
rm -rf "$STUB"

guard_setup; printf '#!/bin/bash\n: > "$STUB/pf_fail"; touch "$STUB/ifconfig_fail" "$STUB/ifconfig_read_fail"; rm -f "$STUB/ssh_up"\n' > "$hook"; gt 2 "$hook"
expect_eq "guard: an unreadable interface is never reported as taken down" \
  "$(st error | grep -c 'could NOT confirm taken down: utun7') $(st error | grep -c '; taken down:')" "1 0"
rm -rf "$STUB"

guard_setup; echo AI_NETS=none >> "$STUB/conf"; printf '#!/bin/bash\necho direct > "$STUB/db/mode"; touch "$STUB/flush_fail"\n' > "$hook"; gt 2 "$hook"
expect_eq "guard: direct mode with rules stuck in pf is a failed switch, not direct" \
  "$(verdict) | $(st error) | $([[ -e $STUB/release.log ]] && echo released || echo kept)" \
  "error | pf did not remove the tunlock rules | kept"
rm -rf "$STUB"

guard_setup; echo AI_NETS=none >> "$STUB/conf"; printf '#!/bin/bash\necho direct > "$STUB/db/mode"; touch "$STUB/read_fail"\n' > "$hook"; gt 2 "$hook"
expect_eq "guard: direct mode when pf does not answer is a failed switch" "$(verdict) | $(st error)" \
  "error | pf did not answer; tunlock rules may still be loaded"
rm -rf "$STUB"

# Direct mode: everything goes directly, except the AI networks (#35)
guard_setup; printf '#!/bin/bash\n[[ $1 == 0 ]] && echo direct > "$STUB/db/mode"\nexit 0\n' > "$hook"; gt 3 "$hook"
expect_eq "direct: only the AI networks stay closed, on every interface" \
  "$(verdict) | $(grep -vc '^$' "$STUB/anchor") | $(grep -c 'quick inet from any to 160.79.104.0/21 label' "$STUB/anchor") $(grep -c 'quick inet6 from any to 2607:6bc0::/32 label' "$STUB/anchor") | $(grep -c 'block drop quick all' "$STUB/anchor")" \
  "direct | 2 | 1 1 | 0"
expect_eq "direct: the state says the AI networks are closed" "$(st ai_closed) | $(st ai_nets) | $(st reason) | [$(st warning)]" \
  "1 | 160.79.104.0/21 2607:6bc0::/32 | off | []"
expect_eq "direct: open connections to the AI networks are dropped, the rest kept" \
  "$(paste -sd'|' "$STUB/kill.log")" "kill 0.0.0.0/0 160.79.104.0/21|kill ::/0 2607:6bc0::/32"
expect_eq "direct: pf stays enabled with tunlock's reference" "$([[ -e $STUB/enabled ]] && echo on) $([[ -e $STUB/release.log ]] && echo released || echo kept)" "on kept"
out=$(TUNLOCK_CONF=$STUB/conf TUNLOCK_RUN_DIR=$STUB/run $T status 2>&1)
grep -q 'except AI services (Claude): closed' <<< "$out" && grep -q '^Closed   160.79.104.0/21 2607:6bc0::/32' <<< "$out" \
  && ok "direct: status says Claude stays closed" || ko "direct: status says Claude stays closed" "$out"
expect_eq "direct: two ticks in direct mode load the rules once" "$(grep -c 'only the AI networks stay closed' "$STUB/guard.log")" "1"
echo protected > "$STUB/db/mode"; gt 2
expect_eq "direct -> protected: the tunnel rules replace the direct ones" "$(verdict) $(st ai_closed) $(tail -1 "$STUB/anchor" | cut -c1-20)" "protected 1 block drop quick all"
rm -rf "$STUB"
guard_setup; echo direct > "$STUB/db/mode"; : > "$STUB/pf_fail"; gt 2
expect_eq "direct: a rejected AI block is a warning, the switch to direct still holds" \
  "$(verdict) | $(st ai_closed) | $(st warning | cut -c1-41) | [$(st error)]" "direct | 0 | AI networks NOT closed outside the tunnel | []"
rm -rf "$STUB"
guard_setup; echo direct > "$STUB/db/mode"; printf 'pass out quick all\nanchor "com.apple/*" all\n' > "$STUB/root_rules"; gt 2
expect_eq "direct: a rule deciding before tunlock means the AI networks are not closed" \
  "$(verdict) | $(st ai_closed) | $(st warning)" "direct | 0 | AI networks NOT closed outside the tunnel: other pf rules decide before tunlock (tunlock conflicts)"
rm -rf "$STUB"
guard_setup; echo AI_NETS=none >> "$STUB/conf"; echo direct > "$STUB/db/mode"; gt 2
expect_eq "direct: AI_NETS=none keeps the old direct mode, nothing loaded" \
  "$(verdict) | $(st ai_closed) | [$(st ai_nets)] | [$(cat "$STUB/anchor" 2>/dev/null)]" "direct | 0 | [] | []"
rm -rf "$STUB"
bad_conf "an AI network that is not a network" "AI_NETS=claude.ai"
expect_eq "AI_NETS takes custom IPv4 and IPv6 networks" \
  "$(tmpa=$(mktemp); cat "$F/good.conf" > "$tmpa"; echo 'AI_NETS="198.51.100.0/24 2001:db8::/32"' >> "$tmpa"; TUNLOCK_CONF=$tmpa $T render-rules direct | grep -c label; rm -f "$tmpa")" "2"

# pf conflicts: rules that decide before tunlock make "protected" untrue
guard_setup; printf 'scrub-anchor "com.apple/*" all fragment reassemble\npass out quick all\nanchor "com.apple/*" all\n' > "$STUB/root_rules"; gt 2
expect_eq "conflict: a quick rule before our anchor is not protected" \
  "$(verdict) | $(st pf_conflict)" "unprotected | rule evaluated first: pass out quick all"
rm -rf "$STUB"
guard_setup; printf 'anchor "other_lock" quick all\nanchor "com.apple/*" all\n' > "$STUB/root_rules"
echo 'pass out quick on utun3 all' > "$STUB/anchor-other_lock"; gt 2
expect_eq "conflict: another kill switch's anchor evaluated first" "$(verdict) | $(st pf_conflict)" \
  "unprotected | anchor \"other_lock\" is evaluated first"
rm -rf "$STUB"
guard_setup; printf '  com.apple/000.aaa\n  com.apple/000.tunlock\n  com.apple/250.ApplicationFirewall\n' > "$STUB/children-com.apple"
echo 'pass out quick all' > "$STUB/anchor-com.apple_000.aaa"; echo 'pass in quick all' > "$STUB/anchor-com.apple_250.ApplicationFirewall"; gt 2
expect_eq "conflict: only a sibling sorting before ours counts" "$(verdict) | $(st pf_conflict)" \
  "unprotected | anchor com.apple/000.aaa sorts before ours"
rm -rf "$STUB"
conflict_case() { # label, root rules, then pairs of stub file name and contents (\n escapes)
  local root=$2; shift 2
  guard_setup; printf '%b' "$root" > "$STUB/root_rules"
  while (( $# )); do printf '%b' "$2" > "$STUB/$1"; shift 2; done
  gt 2
}
conflict_case x 'anchor "grp/*" quick all\nanchor "com.apple/*" all\n' children-grp '  grp/a\n' anchor-grp_a 'pass out all\n'
expect_eq "conflict: quick on a group call, non-quick rule inside" "$(verdict) | $(st pf_conflict)" \
  "unprotected | anchor grp/a (via \"grp/*\") is evaluated first"; rm -rf "$STUB"
conflict_case x 'anchor "solo" quick all\nanchor "com.apple/*" all\n' anchor-solo 'pass out all\n'
expect_eq "conflict: quick on an anchor call, non-quick rule inside" "$(verdict)" "unprotected"; rm -rf "$STUB"
conflict_case x 'anchor "empty" quick all\nanchor "com.apple/*" all\n'
expect_eq "conflict: an empty quick anchor decides nothing" "$(verdict) | $(st pf_conflict)" "protected | "; rm -rf "$STUB"
conflict_case x 'anchor "outer" all\nanchor "com.apple/*" all\n' anchor-outer 'anchor "inner" quick all\n' anchor-inner 'pass out all\n'
expect_eq "conflict: a nested quick anchor" "$(verdict) | $(st pf_conflict)" "unprotected | anchor \"outer\" is evaluated first"; rm -rf "$STUB"
conflict_case x 'anchor "outer" all\nanchor "com.apple/*" all\n' anchor-outer 'pass out all\n'
expect_eq "conflict: non-quick rules before ours are overridden, no conflict" "$(verdict)" "protected"; rm -rf "$STUB"
conflict_case x 'anchor "grp/*" quick all\nanchor "com.apple/*" all\n' children-grp '  grp/a\n' anchor-grp_a 'pass out all\n' anchors_fail ''
expect_eq "conflict: an unreadable group listing is a conflict, not an empty group" \
  "$(verdict) | $(st pf_conflict | grep -c 'cannot list the anchors under "grp/\*"')" "unprotected | 1"; rm -rf "$STUB"
conflict_case x 'anchor "com.apple/*" all\n' anchors_fail ''
expect_eq "conflict: unreadable siblings of our anchor are a conflict" "$(verdict) | $(st pf_conflict)" \
  "unprotected | cannot list the anchors under \"com.apple\""; rm -rf "$STUB"
conflict_case x 'anchor "com.apple/*" quick all\n' children-com.apple '  com.apple/000.aaa\n  com.apple/000.tunlock\n' anchor-com.apple_000.aaa 'pass out all\n'
expect_eq "conflict: quick on com.apple/* makes an earlier sibling decide" "$(verdict) | $(st pf_conflict)" \
  "unprotected | anchor com.apple/000.aaa sorts before ours"; rm -rf "$STUB"

guard_setup; printf 'scrub-anchor "com.apple/*" all fragment reassemble\nanchor "com.apple/*" all\n' > "$STUB/root_rules"; gt 2
expect_eq "conflict: stock macOS layout has none" "$(verdict) | $(st pf_conflict)" "protected | "
rm -rf "$STUB"

# Before sleep: the tunnel closes and the helper is told; no reopening until wake
guard_setup; printf '#!/bin/bash\n[[ $1 == 0 ]] && touch "$STUB/run/sleep-request"\nexit 0\n' > "$hook"; chmod +x "$hook"; gt 3 "$hook"
expect_eq "sleep: the tunnel closes before the Mac sleeps and the helper is told" \
  "$(st phase) $(st egress_ok) $([[ -e $STUB/run/sleep-ack ]] && echo ack)" "probe 0 ack"
rm -f "$STUB/run/sleep-request" "$STUB/run/sleep-ack"; gt 2
expect_eq "sleep: after wake it reopens only after a fresh check" "$(st phase) $(st egress_ok)" "open 1"
rm -rf "$STUB"

# Block reasons: one code from the guard, the same order as the verdict
reason() { TUNLOCK_CONF=$STUB/conf TUNLOCK_RUN_DIR=$STUB/run $T status --porcelain | awk -F= '$1 == "reason" { print $2 }'; }
human() { TUNLOCK_CONF=$STUB/conf TUNLOCK_RUN_DIR=$STUB/run $T status 2>&1 || true; }
reason_case() { # label, expected "verdict reason egress_check", setup commands (eval'd), ticks
  guard_setup; eval "$3"; gt "${4:-2}"
  expect_eq "reason: $1" "$(verdict) $(reason) $(st egress_check)" "$2"
  expect_eq "reason: $1 (porcelain has one reason line)" "$(TUNLOCK_CONF=$STUB/conf TUNLOCK_RUN_DIR=$STUB/run $T status --porcelain | grep -c '^reason=')" "1"
}
reason_case "verified exit" "protected ok ok" ":"; rm -rf "$STUB"
reason_case "no TUN interface" "blocked no_tun pending" "sed -i '' 's/^utun7:/utunX:/' \"\$STUB/ifconfig.txt\""
grep -q 'no TUN interface; turn on your TUN app' <<< "$(human)" && ok "reason: status says what to do without TUN" \
  || ko "reason: status says what to do without TUN" "$(human)"; rm -rf "$STUB"
reason_case "SSH forward down" "blocked ssh_down pending" "rm -f \"\$STUB/ssh_up\""; rm -rf "$STUB"
reason_case "unexpected exit" "blocked exit_mismatch mismatch" "echo 198.51.100.9 > \"\$STUB/egress\""
grep -q 'Egress   198.51.100.9 (NOT expected' <<< "$(human)" && ok "reason: an unexpected exit is shown as such" \
  || ko "reason: an unexpected exit is shown as such" "$(human)"; rm -rf "$STUB"
reason_case "exit check without an answer" "blocked exit_no_answer no_answer" "rm -f \"\$STUB/egress\""
grep -q 'Egress   no answer through the tunnel' <<< "$(human)" && ok "reason: no answer is not called a wrong exit" \
  || ko "reason: no answer is not called a wrong exit" "$(human)"; rm -rf "$STUB"
reason_case "rejected pf load" "unprotected pf_error pending" ": > \"\$STUB/pf_fail\""; rm -rf "$STUB"
reason_case "pf conflict" "unprotected pf_conflict ok" "printf 'pass out quick all\nanchor \"com.apple/*\" all\n' > \"\$STUB/root_rules\""; rm -rf "$STUB"
reason_case "direct mode" "direct off pending" "echo direct > \"\$STUB/db/mode\""
human | grep -q '^Reason' && ko "reason: direct mode has no Reason line" "$(human)" || ok "reason: direct mode has no Reason line"; rm -rf "$STUB"
guard_setup; printf '#!/bin/bash\n[[ $1 == 0 ]] && touch "$STUB/run/sleep-request"\nexit 0\n' > "$hook"; chmod +x "$hook"; gt 3 "$hook"
expect_eq "reason: going to sleep" "$(verdict) $(reason)" "blocked sleep"; rm -rf "$STUB"
# Proxy: the TCP port check and the exit check are separate results
reason_case "proxy port open, exit not ours" "blocked exit_mismatch mismatch" \
  "printf 'UPSTREAM=proxy\nPROXY_HOST=198.51.100.20\nPROXY_PORT=8080\nEXPECTED_EGRESS=203.0.113.10\nTUN_ADDR=10.20.0.1\nTUN_MASK=0xfffffffc\n' > \"\$STUB/conf\"; echo 198.51.100.9 > \"\$STUB/egress\""
out=$(human)
grep -q '^Proxy    TCP port open  198.51.100.20:8080' <<< "$out" && grep -q '^Reason   exit_mismatch' <<< "$out" \
  && ok "reason: an open proxy port and an unverified exit are both shown" || ko "reason: an open proxy port and an unverified exit are both shown" "$out"
rm -rf "$STUB"
reason_case "proxy port closed" "blocked entry_down no_answer" \
  "printf 'UPSTREAM=proxy\nPROXY_HOST=198.51.100.20\nPROXY_PORT=8080\nTUN_ADDR=10.20.0.1\nTUN_MASK=0xfffffffc\n' > \"\$STUB/conf\"; touch \"\$STUB/entry_down\"; rm -f \"\$STUB/egress\""
grep -q '^Proxy    TCP port closed' <<< "$(human)" && ok "reason: a closed proxy port is shown" || ko "reason: a closed proxy port is shown" "$(human)"
rm -rf "$STUB"
# Cascade: a wrong exit seen through a working SSH outranks a failed entry probe
reason_case "cascade: wrong exit with the entry probe failing" "blocked exit_mismatch mismatch" \
  "cat \"\$F/cascade.extra\" >> \"\$STUB/conf\"; touch \"\$STUB/entry_down\"; echo 198.51.100.9 > \"\$STUB/egress\""
grep -q '^Entry    TCP port closed' <<< "$(human)" && ok "reason: the failed entry probe stays visible" || ko "reason: the failed entry probe stays visible" "$(human)"
rm -rf "$STUB"
reason_case "cascade: entry down, exit not answering" "blocked entry_down no_answer" \
  "cat \"\$F/cascade.extra\" >> \"\$STUB/conf\"; touch \"\$STUB/entry_down\"; rm -f \"\$STUB/egress\""
rm -rf "$STUB"
# Old or missing state: say so, never repeat the old reason
guard_setup; gt 2; sed -i '' "s/^updated=.*/updated=$(( $(date +%s) - 60 ))/" "$STUB/run/state"
expect_eq "reason: stale state is stale, not the old reason" "$(verdict) $(reason)" "unknown stale"; rm -rf "$STUB"
guard_setup
expect_eq "reason: no state at all" "$(reason)" "no_state"; rm -rf "$STUB"
guard_setup; gt 2; sed -i '' '/^reason=/d' "$STUB/run/state"
expect_eq "reason: a guard that writes no reason gives unknown, not a guess" "$(reason)" "unknown"; rm -rf "$STUB"

# tunlock run: the command starts only after a fresh check for this request
printf '#!/bin/bash\nprintf "%%s|" "$@"; exit 7\n' > "$hook.prog"; chmod +x "$hook.prog"
# run_case setup -- run args...: the guard ticks until the client is done,
# like the real one. Leaves $STUB/run.rc and $STUB/run.out; the client reads
# $RUN_CONF if set (a config edited after the guard started).
run_case() {
  local setup=$1; shift 2
  guard_setup; gt 1; eval "$setup"
  ( TUNLOCK_TEST_PATH=$STUBS TUNLOCK_CONF=${RUN_CONF:-$STUB/conf} TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run \
      $T run "$@" > "$STUB/run.out" 2>&1; echo $? > "$STUB/run.rc" ) &
  local i
  for (( i = 0; i < 40; i++ )); do
    [[ -e $STUB/run.rc ]] && break
    gt 1; sleep 0.2
  done
  wait
}
rr() { echo "$(cat "$STUB/run.rc") $(grep -c "$1" "$STUB/run.out")"; }
run_case : -- --timeout 5 -- "$hook.prog" "a b" '$x' ''
expect_eq "run: a verified exit starts the command with its arguments and status" \
  "$(cat "$STUB/run.rc") $(tail -1 "$STUB/run.out")" '7 a b|$x||'
expect_eq "run: says which exit was verified" "$(grep -c 'exit 203.0.113.10 verified' "$STUB/run.out")" "1"; rm -rf "$STUB"
run_case : -- --quiet --timeout 5 -- "$hook.prog" q
expect_eq "run: --quiet prints only the command's output" "$(cat "$STUB/run.rc") $(cat "$STUB/run.out")" "7 q|"; rm -rf "$STUB"
mkdir -p "$hook.bin"; cp "$hook.prog" "$hook.bin/myprog"
PATH=$hook.bin:$PATH run_case : -- --quiet --timeout 5 -- myprog p
expect_eq "run: the command is looked up in the caller's PATH" "$(cat "$STUB/run.rc") $(cat "$STUB/run.out")" "7 p|"
rm -rf "$STUB" "$hook.bin"
run_case 'echo direct > "$STUB/db/mode"' -- --timeout 5 -- "$hook.prog"
expect_eq "run: direct mode refuses at once" "$(rr 'not started: off')" "125 1"; rm -rf "$STUB"
run_case 'echo 198.51.100.9 > "$STUB/egress"' -- --timeout 5 -- "$hook.prog"
expect_eq "run: an unexpected exit refuses at once" "$(rr 'not started: exit_mismatch')" "125 1"; rm -rf "$STUB"
run_case "sed -i '' 's/^utun7:/utunX:/' \"\$STUB/ifconfig.txt\"" -- --timeout 2 -- "$hook.prog"
expect_eq "run: no TUN interface refuses after the timeout with the reason" "$(rr 'not started: no_tun')" "125 1"; rm -rf "$STUB"
run_case 'rm -f "$STUB/egress"' -- --timeout 2 -- "$hook.prog"
expect_eq "run: an exit that stops answering refuses, even if it was verified before" "$(rr 'not started: exit_no_answer')" "125 1"; rm -rf "$STUB"
RUN_CONF=$hook.conf run_case '{ cat "$STUB/conf"; echo "# edited"; } > "$hook.conf"' -- --timeout 5 -- "$hook.prog"
expect_eq "run: a config changed after the guard started refuses" "$(rr 'configuration changed')" "125 1"; rm -rf "$STUB" "$hook.conf"
run_case 'echo 1 > "$STUB/stat_uid"' -- --timeout 2 -- "$hook.prog"
expect_eq "run: a request from a system account gets no answer" "$(rr 'no answer from the guard')" "125 1"; rm -rf "$STUB"
expect_eq "run: an unknown command is 127 and asks nothing" \
  "$(TUNLOCK_TEST_PATH=$STUBS TUNLOCK_CONF=$F/good.conf $T run -- no-such-cmd-xyz >/dev/null 2>&1; echo $?)" "127"
expect_eq "run: without -- arguments it is a usage error" \
  "$(TUNLOCK_TEST_PATH=$STUBS TUNLOCK_CONF=$F/good.conf $T run >/dev/null 2>&1; echo $?)" "2"
guard_setup; gt 1; rm -rf "$STUB/run/check"
TUNLOCK_TEST_PATH=$STUBS TUNLOCK_CONF=$STUB/conf TUNLOCK_RUN_DIR=$STUB/run $T run -- "$hook.prog" > "$STUB/run.out" 2>&1; echo $? > "$STUB/run.rc"
expect_eq "run: a guard without the check channel refuses" "$(rr 'takes no checks')" "125 1"; rm -rf "$STUB"
# The queue is read by a background scanner: wait for it like the next tick would.
scan_wait() { local i; for (( i = 0; i < 50; i++ )); do [[ -e $STUB/run/check.scan ]] || return 0; sleep 0.1; done; }
guard_setup; gt 1; scan_wait; echo keep > "$STUB/target"; ln -s "$STUB/target" "$STUB/run/check/0123456789abcdef0123456789abcdef"; : > "$STUB/run/check/not-an-id"; gt 1; scan_wait; gt 1; scan_wait
expect_eq "run: the guard drops links and bad names without following them" \
  "$(cat "$STUB/target") $(find "$STUB/run/check" "$STUB/run/answer" -mindepth 1 | wc -l | tr -d ' ')" "keep 0"
rm -rf "$STUB"
guard_setup; gt 1; scan_wait
for i in $(seq 1 40); do : > "$STUB/run/check/junk$i"; done
: > "$STUB/run/check/0123456789abcdef0123456789abcdef"
gt 1; scan_wait
expect_eq "run: a scan looks at a bounded number of queue entries" \
  "$(find "$STUB/run/check" -mindepth 1 | wc -l | tr -d ' ')" "25"
rm -rf "$STUB"
slow_find=$(mktemp -d); cp "$STUBS"/* "$slow_find/"; printf '#!/bin/bash\n[[ $1 == */check ]] && sleep 6\nexec /usr/bin/find "$@"\n' > "$slow_find/find"; chmod +x "$slow_find/find"
guard_setup; t0=$(date +%s)
TUNLOCK_TEST_PATH=$slow_find TUNLOCK_CONF=$STUB/conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run \
  TUNLOCK_RESOLVER_DIR=$STUB/resolver TUNLOCK_TEST_IFCONFIG=$STUB/ifconfig.txt $T _guard-ticks 2 > "$STUB/guard.log" 2>&1
expect_eq "run: a slow queue listing never holds up the guard's tick" \
  "$(( $(date +%s) - t0 < 4 )) $(st phase)" "1 open"
pkill -f "$slow_find/find" 2>/dev/null || true; rm -rf "$STUB" "$slow_find"
# A directory where the answer's temporary file goes: the write must fail.
guard_setup; gt 1; scan_wait; mkdir "$STUB/run/answer/.0123456789abcdef0123456789abcdef"; : > "$STUB/run/check/0123456789abcdef0123456789abcdef"
gt 1; scan_wait; gt 1; rc=$?
expect_eq "run: an answer that cannot be written is logged, the guard keeps running" \
  "$rc $(grep -c 'could not answer a tunlock run check' "$STUB/guard.log")" "0 1"
scan_wait; rm -rf "$STUB/run/check" "$STUB/run/answer"; gt 1
expect_eq "run: removed check directories are made again" \
  "$([[ -d $STUB/run/check && -k $STUB/run/check ]] && echo sticky) $([[ -d $STUB/run/answer ]] && echo answer)" "sticky answer"
rm -rf "$STUB" "$hook.prog"

guard_setup; echo "req-42" > "$STUB/db/request"; gt 1
expect_eq "guard: echoes the request id it has applied" "$(st ack) $(st mode)" "req-42 protected"
rm -rf "$STUB"

guard_setup; gt 1
expect_eq "routes: a working route is left alone" "$([[ -e $STUB/route.log ]] && cat "$STUB/route.log")" ""
rm -rf "$STUB" "$hook"

guard_setup
echo "192.168.0.0/24 192.168.1.1 en0 192.168.1.208" > "$STUB/run/routes"
echo "192.168.1.45" > "$STUB/route_source"
echo "192.168.1.208" > "$STUB/physical_ipv4"
gt 2
expect_eq "routes: stale kernel source is rebound once despite a current record" \
  "$(cat "$STUB/route.log")" 'change 192.168.0.0/24 192.168.1.1 -ifp en0 -ifa 192.168.1.208'
expect_eq "routes: kernel uses the current source address" "$(cat "$STUB/route_source")" "192.168.1.208"
rm -rf "$STUB"
guard_setup
echo "192.168.0.0/24 192.168.1.1 en0 192.168.1.208" > "$STUB/run/routes"
echo "192.168.1.45" > "$STUB/route_source"; echo "192.168.1.45" > "$STUB/probe_route_source"
echo "192.168.1.208" > "$STUB/physical_ipv4"
gt 4
expect_eq "routes: a stale cloned host route does not trigger a change every tick" \
  "$(grep -c '^change' "$STUB/route.log")" "1"
rm -rf "$STUB"
guard_setup
echo "192.168.0.0/24 192.168.1.1 en0 192.168.1.208" > "$STUB/run/routes"
echo "192.168.1.208" > "$STUB/physical_ipv4"
gt 2
expect_eq "routes: an unknown kernel source is never a reason to change" \
  "$([[ -e $STUB/route.log ]] && cat "$STUB/route.log")" ""
rm -rf "$STUB"

# ---- protect/direct: success only when the guard answers this very request
# fake_guard mode phase pf_enabled [error] [answer=1]: a background responder
# that echoes the request id, like the real guard; answer=0 never answers.
fake_guard() {
  STUB=$(mktemp -d); mkdir -p "$STUB/db" "$STUB/run"
  # A fresh-looking snapshot from before the command: must never count.
  printf 'updated=%s\nack=old\nmode=%s\nphase=%s\npf_enabled=%s\npf_rules=7\npf_reachable=1\nssh=%s\nerror=%s\n' \
    "$(date +%s)" "$1" "$2" "$3" "${FAKE_SSH:-up}" "${4:-}" > "$STUB/run/state"
  [[ ${5:-1} == 1 ]] || return 0
  (
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if [[ -s $STUB/db/request ]]; then
        printf 'updated=%s\nack=%s\nmode=%s\nphase=%s\npf_enabled=%s\npf_rules=7\npf_reachable=1\nssh=%s\nerror=%s\n' \
          "$(date +%s)" "$(cat "$STUB/db/request")" "$(cat "$STUB/db/mode")" "$2" "$3" "${FAKE_SSH:-up}" "${4:-}" > "$STUB/run/state"
        exit 0
      fi
      sleep 0.3
    done
  ) &
}
cli() { export STUB; TUNLOCK_TEST_PATH=$STUBS TUNLOCK_CONF=$F/good.conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run $T "$@" >/dev/null 2>&1; echo $?; }
done_guard() { wait; rm -rf "$STUB"; }
fake_guard protected open 1 "" 0; expect_eq "protect fails on a fresh snapshot the guard never answered" "$(cli protect)" "1"; done_guard
fake_guard direct direct 1 "" 0;  expect_eq "direct fails on a fresh snapshot the guard never answered" "$(cli direct)" "1"; done_guard
fake_guard protected open 0;      expect_eq "protect fails when pf is disabled" "$(cli protect)" "1"; done_guard
fake_guard protected open 1 "pf rejected"; expect_eq "protect fails on a guard error" "$(cli protect)" "1"; done_guard
fake_guard protected failed 1;    expect_eq "protect fails when no phase is confirmed" "$(cli protect)" "1"; done_guard
fake_guard protected open 1;      expect_eq "protect succeeds when the guard confirms protected" "$(cli protect)" "0"; done_guard
fake_guard protected block 1;     expect_eq "protect succeeds when the guard confirms blocked" "$(cli protect)" "0"; done_guard
fake_guard direct direct 1;       expect_eq "direct succeeds when the guard confirms direct" "$(cli direct)" "0"; done_guard
STUB=$(mktemp -d); mkdir -p "$STUB/db" "$STUB/run"; echo 4242 > "$STUB/run/token"
echo 'block drop quick all label "tunlock-x"' > "$STUB/anchor"; touch "$STUB/flush_fail"
expect_eq "direct without a guard fails when pf keeps the rules, and keeps the token" \
  "$(TUNLOCK_TEST_NO_GUARD=1 cli direct) $(cat "$STUB/run/token") $([[ -e $STUB/release.log ]] && echo released || echo kept)" "1 4242 kept"
rm -f "$STUB/flush_fail"; touch "$STUB/read_fail"
expect_eq "direct without a guard fails when pf does not answer the read" \
  "$(TUNLOCK_TEST_NO_GUARD=1 cli direct) $(cat "$STUB/run/token") $([[ -e $STUB/release.log ]] && echo released || echo kept)" "1 4242 kept"
rm -f "$STUB/read_fail"; touch "$STUB/release_fail"
expect_eq "direct without a guard fails when pf refuses to release the reference" \
  "$(TUNLOCK_TEST_NO_GUARD=1 cli direct) $(cat "$STUB/run/token")" "1 4242"
rm -f "$STUB/release_fail"
expect_eq "direct without a guard succeeds once the rules are really gone" \
  "$(TUNLOCK_TEST_NO_GUARD=1 cli direct) $([[ -e $STUB/run/token ]] && echo token || echo none) $(cat "$STUB/release.log")" "0 none released"
rm -rf "$STUB"
# The app's confirmation is checked again as root, just before the rules go.
ack_off() { # ack contents, path dir: exit code, mode written, ack left or used
  STUB=$(mktemp -d); mkdir -p "$STUB/db" "$STUB/run"; printf '%s\n' "$1" > "$STUB/ack"
  export STUB
  local rc
  rc=$(TUNLOCK_AI_APPS="nope bash" TUNLOCK_OFF_ACK=$STUB/ack TUNLOCK_TEST_NO_GUARD=1 TUNLOCK_TEST_PATH=${2:-$STUBS} TUNLOCK_CONF=$F/good.conf \
    TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run $T off >/dev/null 2>&1; echo $?)
  echo "$rc $(cat "$STUB/db/mode" 2>/dev/null || echo unchanged) $([[ -e $STUB/ack ]] && echo left || echo used)"
  rm -rf "$STUB"
}
psok=$(mktemp -d)
cp "$STUBS"/* "$psok/"
printf '#!/bin/bash\nprintf "%%s\\n" /bin/bash\n' > "$psok/ps"
chmod +x "$psok/ps"
expect_eq "off: a client started after the app's confirmation keeps protection on" "$(ack_off "" "$psok")" "1 unchanged used"
expect_eq "off: clients the user confirmed in the app do not stop it" "$(ack_off "bash" "$psok")" "0 direct used"
rm -rf "$psok"
psfail=$(mktemp -d); cp "$STUBS"/* "$psfail/"; printf '#!/bin/bash\nexit 1\n' > "$psfail/ps"; chmod +x "$psfail/ps"
expect_eq "off: a failed recheck keeps protection on" "$(ack_off "bash" "$psfail")" "1 unchanged used"
expect_eq "off: a failed recheck passes when the user confirmed a failed check" "$(ack_off "?" "$psfail")" "0 direct used"
rm -rf "$psfail"
# on/off drive the TUN client and the SSH keeper, after the guard confirms
# With a proxy upstream "on" starts the TUN client itself (with SSH the guard does)
svc_conf=$(mktemp); printf 'UPSTREAM=proxy\nPROXY_HOST=198.51.100.20\nPROXY_PORT=8080\nTUN_ADDR=10.20.0.1\nTUN_MASK=0xfffffffc\nTUN_SERVICE=Karing\n' > "$svc_conf"
clis() { export STUB; TUNLOCK_TEST_PATH=$STUBS TUNLOCK_CONF=$svc_conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run $T "$@" >/dev/null 2>&1; echo $?; }
fake_guard protected open 1
expect_eq "on: the CLI never starts the TUN client itself, the guard does" "$(clis on) | $(cat "$STUB/scutil.log" 2>/dev/null)" "0 | "; done_guard
ssh_svc_conf=$(mktemp); { cat "$F/good.conf"; echo 'TUN_SERVICE="Karing"'; } > "$ssh_svc_conf"
fake_guard protected open 1
expect_eq "on: with SSH the start is left to the guard, never done by the CLI" \
  "$(TUNLOCK_TEST_PATH=$STUBS TUNLOCK_CONF=$ssh_svc_conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run $T on >/dev/null 2>&1; echo $?) | $(cat "$STUB/scutil.log" 2>/dev/null)" "0 | "; done_guard
fake_guard protected open 1
expect_eq "off: with SSH stops the TUN client too" \
  "$(echo direct > "$STUB/db/mode"; TUNLOCK_TEST_PATH=$STUBS TUNLOCK_CONF=$ssh_svc_conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run $T off >/dev/null 2>&1; echo $?) | $(cat "$STUB/scutil.log" 2>/dev/null)" "0 | --nc stop Karing"; done_guard
rm -f "$ssh_svc_conf"
fake_guard protected open 0
expect_eq "on: TUN client NOT started when protection is not confirmed" "$(clis on) | $(cat "$STUB/scutil.log" 2>/dev/null)" "1 | "; done_guard
fake_guard direct direct 1
expect_eq "off: frees the SSH port and stops the TUN client" \
  "$(clis off) | $(grep -c 'kickstart -k gui/501/tunlock.ssh' "$STUB/launchctl.log") | $(cat "$STUB/scutil.log")" "0 | 1 | --nc stop Karing"; done_guard
fake_guard protected open 1 "" 0
expect_eq "off: nothing is stopped while direct is not confirmed" \
  "$(clis off) | $([[ -e $STUB/scutil.log || -e $STUB/launchctl.log ]] && echo touched || echo untouched)" "1 | untouched"; done_guard
rm -f "$svc_conf"

# ---- a TUN client update may orphan the configured service: control the live one
svc2_conf=$(mktemp); printf 'UPSTREAM=proxy\nPROXY_HOST=198.51.100.20\nPROXY_PORT=8080\nTUN_ADDR=10.20.0.1\nTUN_MASK=0xfffffffc\nTUN_SERVICE=Karing\n' > "$svc2_conf"
clis2() { export STUB; TUNLOCK_TEST_PATH=$STUBS TUNLOCK_CONF=$svc2_conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run $T "$@" >/dev/null 2>&1; echo $?; }
export STUB_NC_LIST=$F/nc-list.karing.txt STUB_NC_SHOW_DIR=$F/nc-show STUB_SYSEXT=$F/sysext.karing.txt
fake_guard protected open 1
expect_eq "off: an orphaned service is replaced by its live rename" \
  "$(clis2 off) | $(tail -1 "$STUB/scutil.log")" "0 | --nc stop 00000000-0000-4000-8000-000000000001"; done_guard
fake_guard protected open 1
expect_eq "off: stops the same live service" \
  "$(clis2 off) | $(tail -1 "$STUB/scutil.log")" "0 | --nc stop 00000000-0000-4000-8000-000000000001"; done_guard
export STUB_SYSEXT=$F/sysext.both.txt
fake_guard protected open 1
expect_eq "off: the configured service wins while its provider is live" \
  "$(clis2 off) | $(tail -1 "$STUB/scutil.log")" "0 | --nc stop 00000000-0000-4000-8000-000000000002"; done_guard
export STUB_NC_LIST=$F/nc-list.other.txt
fake_guard protected open 1
expect_eq "off: a configured service that is gone is not swapped for another" \
  "$(clis2 off) | $(cat "$STUB/scutil.log" 2>/dev/null)" "0 | --nc stop Karing"; done_guard
export STUB_NC_LIST=$F/nc-list.ambiguous.txt STUB_SYSEXT=$F/sysext.karing.txt
fake_guard protected open 1
expect_eq "off: without the old service a lookalike is never taken" \
  "$(clis2 off) | $(cat "$STUB/scutil.log" 2>/dev/null)" "0 | --nc stop Karing"; done_guard
export STUB_NC_LIST=$F/nc-list.otherapp.txt
fake_guard protected open 1
expect_eq "off: a lookalike name from another app is never taken" \
  "$(clis2 off) | $(tail -1 "$STUB/scutil.log")" "0 | --nc stop 00000000-0000-4000-8000-000000000002"; done_guard
unset STUB_NC_LIST STUB_NC_SHOW_DIR STUB_SYSEXT
rm -f "$svc2_conf"

# Proxy upstream: no SSH forward to wait for, the client starts right away
pxs_conf=$(mktemp); printf 'UPSTREAM=proxy\nPROXY_HOST=198.51.100.20\nPROXY_PORT=8080\nTUN_ADDR=10.20.0.1\nTUN_MASK=0xfffffffc\nTUN_SERVICE=Karing\n' > "$pxs_conf"
FAKE_SSH=none fake_guard protected open 1
expect_eq "on: with a proxy upstream the CLI does not wait for SSH and leaves the start to the guard" \
  "$(TUNLOCK_TEST_PATH=$STUBS TUNLOCK_CONF=$pxs_conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run $T on 2>&1 | grep -c 'once the proxy port answers') | $(cat "$STUB/scutil.log" 2>/dev/null)" "1 | "; done_guard
rm -f "$pxs_conf"

# ---- the guard restarts a TUN client that gave up while the forward was down
guard_setup
{ cat "$F/good.conf"; echo 'TUN_SERVICE="Karing"'; echo 'TUN_ADDR=10.99.0.1'; echo PROBE_INTERVAL=5; } > "$STUB/conf"
export STUB_NC_LIST=$F/nc-list.karing.txt STUB_NC_SHOW_DIR=$F/nc-show STUB_SYSEXT=$F/sysext.karing.txt
gt 2
expect_eq "guard: starts the TUN client once the forward is up and no tunnel is" \
  "$(st phase) | $(grep -c 'nc start 00000000-0000-4000-8000-000000000001' "$STUB/scutil.log" 2>/dev/null)" "block | 1"
unset STUB_NC_LIST STUB_NC_SHOW_DIR STUB_SYSEXT
rm -rf "$STUB"
svc_guard() { # extra conf lines; then gt args
  guard_setup; { cat "$F/good.conf"; echo 'TUN_SERVICE="Karing"'; echo PROBE_INTERVAL=5; printf '%b' "$1"; } > "$STUB/conf"; shift
  gt "$@"
}
svc_guard 'TUN_ADDR=10.99.0.1\n' 3
expect_eq "guard: one start per minute, not one per tick" "$(grep -c 'nc start' "$STUB/scutil.log")" "1"; rm -rf "$STUB"
guard_setup; : > "$STUB/pf_fail"; rm -f "$STUB/egress"
{ cat "$F/good.conf"; echo 'TUN_SERVICE="Karing"'; echo 'TUN_ADDR=10.99.0.1'; } > "$STUB/conf"; gt 2
expect_eq "guard: never starts the TUN client while pf rules are not confirmed" \
  "$([[ -e $STUB/scutil.log ]] && cat "$STUB/scutil.log")" ""; rm -rf "$STUB"
guard_setup; printf 'pass out quick all\nanchor "com.apple/*" all\n' > "$STUB/root_rules"
{ cat "$F/good.conf"; echo 'TUN_SERVICE="Karing"'; echo 'TUN_ADDR=10.99.0.1'; } > "$STUB/conf"; gt 2
expect_eq "guard: never starts the TUN client while other pf rules decide first" \
  "$([[ -e $STUB/scutil.log ]] && cat "$STUB/scutil.log") | $(grep -c 'pf protection is not confirmed' "$STUB/guard.log")" " | 1"; rm -rf "$STUB"
export STUB_NC_LIST=$F/nc-list.ambiguous.txt
svc_guard 'TUN_ADDR=10.99.0.1\n' 1
expect_eq "guard: a configured TUN app that is gone shows a warning, nothing is started" \
  "$([[ -e $STUB/scutil.log ]] && cat "$STUB/scutil.log") | $(st warning | grep -c 'no longer exists (found: Karing (system) Karing (beta))')" " | 1"
unset STUB_NC_LIST; rm -rf "$STUB"
printf '#!/bin/bash\n[[ $1 == 0 ]] && sed -i "" s/^utun7:/utunX:/ "$STUB/ifconfig.txt"\nexit 0\n' > "$hook"; chmod +x "$hook"
svc_guard '' 3 "$hook"
expect_eq "guard: a client stopped after its tunnel was up is not started again" \
  "$([[ -e $STUB/scutil.log ]] && cat "$STUB/scutil.log") | $(st tun)" " | "; rm -rf "$STUB"
svc_guard 'UPSTREAM=proxy\nPROXY_HOST=198.51.100.20\nPROXY_PORT=8080\nTUN_ADDR=10.99.0.1\n' 2
expect_eq "guard: with a proxy upstream it starts the client once the proxy port answers" \
  "$(grep -c 'nc start' "$STUB/scutil.log" 2>/dev/null)" "1"; rm -rf "$STUB"

# A failing "scutil --nc list" must not end the guard
nc_fail=$(mktemp -d); cp "$STUBS"/* "$nc_fail/"
printf '#!/bin/bash\n[[ $1 == --nc && $2 == list ]] && exit 1\necho "$*" >> "$STUB/scutil.log"\n' > "$nc_fail/scutil"; chmod +x "$nc_fail/scutil"
guard_setup; { cat "$F/good.conf"; echo 'TUN_SERVICE="Karing"'; echo 'TUN_ADDR=10.99.0.1'; } > "$STUB/conf"
TUNLOCK_TEST_PATH=$nc_fail TUNLOCK_CONF=$STUB/conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run \
  TUNLOCK_RESOLVER_DIR=$STUB/resolver TUNLOCK_TEST_IFCONFIG=$STUB/ifconfig.txt $T _guard-ticks 2 > "$STUB/guard.log" 2>&1; rc=$?
expect_eq "guard: a failed VPN service listing is retried, the guard keeps running" "$rc $(st phase)" "0 block"
rm -rf "$STUB" "$nc_fail"

# The SSH keeper backs off between failed attempts instead of exiting
ssh_stubs=$(mktemp -d); cp "$STUBS"/* "$ssh_stubs/"
# ssh records the -B interface; the second attempt finds Ethernet instead of Wi-Fi
printf '#!/bin/bash\nwhile (( $# )); do [[ $1 == -B ]] && echo "$2" >> "$STUB/ssh.log"; shift; done\necho en7 > "$STUB/phys"\n(( $(wc -l < "$STUB/ssh.log") >= 3 )) && echo direct > "$STUB/db/mode"\nexit 255\n' > "$ssh_stubs/ssh"
printf '#!/bin/bash\necho "$*" >> "$STUB/sleep.log"\n' > "$ssh_stubs/sleep"
printf '#!/bin/bash\nexit 0\n' > "$ssh_stubs/ssh-add"
printf '#!/bin/bash\necho "default 192.168.1.1 UGScg $(cat "$STUB/phys")"\n' > "$ssh_stubs/netstat"
chmod +x "$ssh_stubs"/*
STUB=$(mktemp -d); export STUB; mkdir -p "$STUB/db" "$STUB/run"; echo protected > "$STUB/db/mode"; echo en0 > "$STUB/phys"
TUNLOCK_TEST_PATH=$ssh_stubs TUNLOCK_CONF=$F/good.conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run $T ssh-run > "$STUB/out" 2>&1; rc=$?
expect_eq "ssh-run: failed attempts wait longer each time, and stop once off" \
  "$rc $(paste -sd' ' "$STUB/ssh.log") $(paste -sd' ' "$STUB/sleep.log")" "0 en0 en7 en7 10 15"
rm -rf "$STUB" "$ssh_stubs"

STUB=$(mktemp -d); mkdir -p "$STUB/db" "$STUB/run"
expect_eq "protect fails without any guard state" "$(cli protect)" "1"; rm -rf "$STUB"
fake_guard protected open 0 "" 0; expect_eq "status exits 1 when not protected" "$(cli status)" "1"; done_guard

# ---- uninstall: never delete state before pf confirms rules and reference are gone
un_setup() {
  STUB=$(mktemp -d); export STUB
  R=$STUB/root
  mkdir -p "$R/prefix/libexec/tunlock" "$R/prefix/etc" "$R/db" "$R/run" "$R/daemons"
  # Installed CLI stand-in: real config parser, every other command a no-op.
  printf '#!/bin/bash\n[[ $1 == config ]] && exec /bin/bash %q config\nexit 0\n' "$PWD/bin/tunlock" > "$R/prefix/libexec/tunlock/tunlock"
  chmod +x "$R/prefix/libexec/tunlock/tunlock"
  cp "$F/good.conf" "$R/prefix/etc/tunlock.conf"
  echo 4242 > "$R/run/token"; echo protected > "$R/db/mode"; : > "$R/daemons/tunlock.guard.plist"
  echo 'block drop quick all label "tunlock-x"' > "$STUB/anchor"
}
un() { SUDO_USER='' TUNLOCK_TEST_PATH=$STUBS TUNLOCK_TEST_ROOT=$R ./uninstall.sh >/dev/null 2>&1; echo $?; }
kept() { [[ -s $R/run/token && -e $R/db/mode && -e $R/daemons/tunlock.guard.plist && -d $R/prefix/libexec/tunlock ]] && echo kept || echo lost; }
un_setup; printf '   PF_ANCHOR="custom/tl"   # indented, quoted, commented\n' >> "$R/prefix/etc/tunlock.conf"
echo 'block drop quick all label "tunlock-x"' > "$STUB/anchor-custom_tl"; : > "$STUB/anchor"; touch "$STUB/flush_fail"
expect_eq "uninstall checks the anchor the config really names" "$(un) $(kept)" "1 kept"
rm -f "$STUB/flush_fail"
expect_eq "uninstall clears the configured anchor" "$(un) $(grep -c tunlock "$STUB/anchor-custom_tl")" "0 0"
rm -rf "$STUB"
un_setup; echo 'PF_ANCHOR=bad anchor!' >> "$R/prefix/etc/tunlock.conf"
expect_eq "uninstall stops when the config cannot be read" "$(un) $(kept)" "1 kept"; rm -rf "$STUB"
un_setup; rm -f "$R/prefix/etc/tunlock.conf"
expect_eq "uninstall works without a config" "$(un)" "0"; rm -rf "$STUB"
un_setup; touch "$STUB/release_fail"
expect_eq "uninstall stops before deleting anything when pf keeps the reference" "$(un) $(kept)" "1 kept"; rm -rf "$STUB"
un_setup; touch "$STUB/read_fail"
expect_eq "uninstall stops before deleting anything when pf does not answer" "$(un) $(kept)" "1 kept"; rm -rf "$STUB"
un_setup; touch "$STUB/flush_fail"
expect_eq "uninstall stops before deleting anything when the rules stay" "$(un) $(kept)" "1 kept"; rm -rf "$STUB"
un_setup
expect_eq "uninstall removes everything once pf confirms" \
  "$(un) $(kept) $(cat "$STUB/release.log") $([[ -e $R/prefix/libexec/tunlock || -e $R/db || -e $R/run ]] && echo leftovers || echo clean)" \
  "0 lost released clean"
rm -rf "$STUB"

# TUN subnet: system-stack clients answer from a peer inside it
expect_eq "tun subnet from the mask" "$(TUNLOCK_CONF=$F/good.conf $T config | grep '^TUN_MASK=')" "TUN_MASK=0xfffffffc"
pr=$(TUNLOCK_CONF=$F/good.conf $T render-rules probe utun7 en0)
expect_eq "probe: the TUN stack's internal leg passes, both ways" \
  "$(grep -c 'on utun7 inet from 10.20.0.0/30 to 10.20.0.0/30 no state' <<< "$pr")" "2"
expect_eq "probe: still only the probe may leave the subnet" \
  "$(grep 'pass out quick on utun7' <<< "$pr" | grep -vc -e '10.20.0.0/30 to 10.20.0.0/30' -e '1.1.1.1 port 443')" "0"
tmpm=$(mktemp); sed 's/^TUN_MASK=.*/TUN_MASK=0xffffff00/' "$F/good.conf" > "$tmpm"
expect_eq "probe: a /24 TUN subnet" "$(TUNLOCK_CONF=$tmpm $T render-rules probe utun7 en0 | grep -c '10.20.0.0/24 to 10.20.0.0/24')" "2"
sed -i '' 's/^TUN_MASK=.*/TUN_MASK=/' "$tmpm"
expect_eq "probe: without a known mask no internal leg is opened" \
  "$(TUNLOCK_CONF=$tmpm $T render-rules probe utun7 en0 | grep -c -e '/32 to' -e '/30 to')" "0"
rm -f "$tmpm"
guard_setup; sed -i '' 's/^TUN_MASK=.*/TUN_MASK=/' "$STUB/conf"; touch "$STUB/egress_never"; rm -f "$STUB/egress"; gt 1
expect_eq "guard: learns the TUN subnet from the interface when no mask is set" \
  "$(grep -c '10.20.0.0/30 to 10.20.0.0/30' "$STUB/anchor")" "2"
rm -rf "$STUB"

# ---- UPSTREAM=proxy: no server, no SSH; the TUN client talks to a proxy directly
pxc=$(mktemp); printf 'UPSTREAM=proxy\nPROXY_HOST=198.51.100.20\nPROXY_PORT=8080\nTUN_ADDR=10.20.0.1\nTUN_MASK=0xfffffffc\n' > "$pxc"
pr=$(TUNLOCK_CONF=$pxc $T render-rules open utun7 en0)
expect_eq "proxy: only the proxy is reachable outside the tunnel (tcp+udp)" \
  "$(grep -c 'to 198.51.100.20 port 8080' <<< "$pr") $(grep -c 'port 22' <<< "$pr")" "2 0"
expect_eq "proxy: the expected exit defaults to the proxy's IP" \
  "$(TUNLOCK_CONF=$pxc $T config | grep -E '^(EXPECTED_EGRESS|ENTRY_HOST)=' | tr '\n' ' ')" "EXPECTED_EGRESS=198.51.100.20 ENTRY_HOST=198.51.100.20 "
expect_eq "proxy: no SSH is run" "$(TUNLOCK_CONF=$pxc $T ssh-command)" "none: UPSTREAM=proxy runs no SSH"
for bad in 'PROXY_HOST=proxy.example.com' 'PROXY_PORT=99999' 'UPSTREAM=vpn'; do
  tmpx=$(mktemp); grep -v "^${bad%%=*}=" "$pxc" > "$tmpx"; echo "$bad" >> "$tmpx"
  if out=$(TUNLOCK_CONF=$tmpx $T config 2>&1); then ko "proxy: rejects $bad" "$out"; else ok "proxy: rejects $bad"; fi
  rm -f "$tmpx"
done
guard_setup; cp "$pxc" "$STUB/conf"; echo PROBE_INTERVAL=5 >> "$STUB/conf"; echo 198.51.100.20 > "$STUB/egress"; rm -f "$STUB/ssh_up"; gt 2
expect_eq "proxy: guard opens once the exit is the proxy's IP, without any SSH" \
  "$(st phase) $(st egress_ok) $(st ssh) $(st upstream) $(verdict)" "open 1 none proxy protected"
rm -rf "$STUB"
guard_setup; cp "$pxc" "$STUB/conf"; echo PROBE_INTERVAL=5 >> "$STUB/conf"; echo 198.51.100.20 > "$STUB/egress"
printf '#!/bin/bash\n[[ $1 == 0 ]] && { rm -f "$STUB/egress"; sleep 6; }\nexit 0\n' > "$hook"; chmod +x "$hook"; gt 2 "$hook"
expect_eq "proxy: proxy stops answering -> tunnel closed" "$(st phase) $(st egress_ok) $(verdict)" "probe 0 blocked"
rm -rf "$STUB"
guard_setup; cp "$pxc" "$STUB/conf"; echo 203.0.113.99 > "$STUB/egress"; gt 2
expect_eq "proxy: a different exit IP never opens" "$(st phase) $(st egress_ok) $(verdict)" "probe 0 blocked"
rm -rf "$STUB" "$pxc"

# The exact file Tunlock.app writes in proxy mode must load
appx=$(mktemp); printf '%s\n' "# Written by Tunlock.app. See tunlock.conf.example for all options." \
  "# The proxy's login and password live only in the TUN app." "UPSTREAM=proxy" "PROXY_HOST=198.51.100.20" \
  "PROXY_PORT=8080" "TUN_ADDR=10.20.0.1" "TUN_MASK=0xfffffffc" "PROBE_INTERVAL=30" 'TUN_SERVICE=""' > "$appx"
if out=$(TUNLOCK_CONF=$appx $T render-rules block "" en0 2>&1); then ok "proxy: the app's config format loads"; else ko "proxy: the app's config format loads" "$out"; fi
rm -f "$appx"

# ---- exit by country: pin an IP, a country, or both
geo() { # extra config lines..., then runs 2 guard ticks
  guard_setup; for l in "$@"; do echo "$l" >> "$STUB/conf"; done; gt 2
}
geo EXPECTED_COUNTRY=NL
expect_eq "geo: pinned IP and the right country opens" "$(st phase) $(st egress_ok) $(st egress_country)" "open 1 NL"; rm -rf "$STUB"
geo EXPECTED_COUNTRY=us
expect_eq "geo: the right IP in the wrong country stays closed" "$(st phase) $(st egress_ok) $(verdict)" "probe 0 blocked"; rm -rf "$STUB"
geo EXPECTED_EGRESS=any EXPECTED_COUNTRY=NL
expect_eq "geo: any IP accepted within the country (rotating exits)" "$(st phase) $(st egress_ok)" "open 1"; rm -rf "$STUB"
guard_setup; printf 'EXPECTED_EGRESS=any\nEXPECTED_COUNTRY=NL\n' >> "$STUB/conf"; echo 192.0.2.77 > "$STUB/egress"; gt 2
expect_eq "geo: a new IP in the same country keeps it open" "$(st phase) $(st egress_ip)" "open 192.0.2.77"; rm -rf "$STUB"
bad_conf "EXPECTED_EGRESS=any without a country" "EXPECTED_EGRESS=any"
bad_conf "a bad country code" "EXPECTED_COUNTRY=USA"

GITHUB_ACTIONS='' TUNLOCK_PF_LIVE=1 bash tests/pf-live.sh >/dev/null 2>&1; rc=$?
expect_eq "pf-live refuses to run outside CI (it would cut the network)" "$rc" "2"

# Restarted guard: reset old connections again only if the outside policy changed
guard_setup; gt 1; gt 1
expect_eq "restart with the same policy keeps connections" "$(wc -l < "$STUB/states.log" | tr -d ' ')" "1"
echo 'BYPASS_NETS="10.9.0.0/16"' >> "$STUB/conf"; gt 1
expect_eq "restart after an exception changed resets old connections" "$(wc -l < "$STUB/states.log" | tr -d ' ')" "2"
sed -i '' 's/^VPS_IP=.*/VPS_IP=203.0.113.11/' "$STUB/conf"; echo 'EXPECTED_EGRESS=203.0.113.10' >> "$STUB/conf"; gt 1
expect_eq "restart after the server/proxy changed resets old connections" "$(wc -l < "$STUB/states.log" | tr -d ' ')" "3"
rm -rf "$STUB"
# Same host and port, proxy -> ssh: proxy allowed UDP too, so reset again
guard_setup; printf 'UPSTREAM=proxy\nPROXY_HOST=203.0.113.10\nPROXY_PORT=22\nTUN_ADDR=10.20.0.1\nTUN_MASK=0xfffffffc\n' > "$STUB/conf"; gt 1
cp "$F/good.conf" "$STUB/conf"; gt 1
expect_eq "restart after proxy -> ssh on the same host:port resets old connections" "$(wc -l < "$STUB/states.log" | tr -d ' ')" "2"
rm -rf "$STUB"

bad_conf "a host name for VPS_IP" "VPS_IP=vps.example.com"
bad_conf "an octet over 255" "VPS_IP=203.0.113.300"
bad_conf "unknown keys" "SSH_OPTS=-o ProxyCommand=evil"
bad_conf "other ssh options in SSH_FORWARD" 'SSH_FORWARD="-o ProxyCommand=x -D 1080"'
bad_conf "shell syntax in SSH_FORWARD" 'SSH_FORWARD="-D 1080;id"'
bad_conf "a probe URL with a host name" "PROBE_URL=https://one.one.one.one/cdn-cgi/trace"
bad_conf "a bad mask" "TUN_MASK=255.255.255.252"
bad_conf "a tiny probe interval" "PROBE_INTERVAL=1"
bad_conf "a bad user" 'SSH_USER=$(id)'

# ---- ai-clients: what would reconnect directly once off
expect_eq "ai-clients finds a running client by process name" "$(TUNLOCK_AI_APPS="nope bash" $T ai-clients)" "bash"
expect_eq "ai-clients is empty and succeeds when none run" "$(TUNLOCK_AI_APPS="nope-1 nope-2" $T ai-clients; echo "rc=$?")" "rc=0"
psfail=$(mktemp -d); printf '#!/bin/bash\nexit 1\n' > "$psfail/ps"; chmod +x "$psfail/ps"
expect_eq "ai-clients fails when the process list cannot be read" \
  "$(TUNLOCK_TEST_PATH=$psfail $T ai-clients 2>&1; echo "rc=$?")" "tunlock: cannot list processes"$'\n'"rc=1"
rm -rf "$psfail"
expect_eq "off without a terminal does not ask (the app asks itself)" \
  "$(S=$(mktemp -d); TUNLOCK_AI_APPS=bash TUNLOCK_TEST_NO_GUARD=1 TUNLOCK_TEST_PATH=$STUBS TUNLOCK_STATE_DIR=$S/db TUNLOCK_RUN_DIR=$S/run STUB=$S $T off 2>&1 | grep -c 'Turn off anyway'; rm -rf "$S")" "0"

# ---- leak test: "no answer" proves blocking only from a target known to answer
# Own stubs: $LT/<switch> files say what answers. direct4/direct6/route6: the
# leak paths; ctrl4: 1.1.1.1 answers through the tunnel; ctrl_udp: 1.1.1.1
# answers DNS through the tunnel as itself (whoami = the exit), ctrl_udp_fake:
# something else answers in its place; udp: the direct UDP query; has6/v6gw:
# the network has IPv6 and an IPv6 router; mac2: another router behind the
# same fe80::1.
LTS=$(mktemp -d); cp "$STUBS"/* "$LTS/"
cat > "$LTS/curl" <<'STUB'
#!/bin/bash
v='' bound=0 url=''
for a in "$@"; do case $a in -4) v=4 ;; -6) v=6 ;; --interface) bound=1 ;; https://*) url=$a ;; esac; done
if [[ $url == */cdn-cgi/trace ]]; then echo "ip=203.0.113.10"; exit 0; fi
case $v$bound in
  41) f=direct4 ;; 40) f=ctrl4 ;; 61) f=direct6 ;; 60) f=route6 ;; *) exit 2 ;;
esac
[[ -e $STUB/$f ]] || exit 28
STUB
cat > "$LTS/nc" <<'STUB'
#!/bin/bash
cat > /dev/null
for a in "$@"; do [[ $a == -b ]] && { [[ ! -e $STUB/udp ]] || printf 'answer'; }; done
exit 0
STUB
cat > "$LTS/ndp" <<'STUB'
#!/bin/bash
echo "Neighbor                                Linklayer Address  Netif Expire    St Flgs Prbs"
[[ -e $STUB/mac2 ]] && mac=aa:bb:cc:00:00:02 || mac=aa:bb:cc:00:00:01
echo "fe80::1%en0                             $mac  en0 permanent R"
STUB
cat > "$LTS/route" <<'STUB'
#!/bin/bash
[[ -e $STUB/v6gw ]] && echo "    gateway: fe80::1%en0"
exit 0
STUB
cat > "$LTS/ifconfig" <<'STUB'
#!/bin/bash
echo "  inet 192.168.1.45 netmask 0xffffff00"
[[ -e $STUB/has6 ]] && echo "  inet6 2001:db8::5 prefixlen 64 autoconf secured"
exit 0
STUB
cat > "$LTS/dig" <<'STUB'
#!/bin/bash
[[ -e $STUB/dig_timeout_all ]] && exit 9
[[ " $* " == *" whoami.cloudflare "* ]] || exit 0
[[ -e $STUB/dig_timeout ]] && exit 9
if [[ -e $STUB/ctrl_udp ]]; then echo '"203.0.113.10"'; elif [[ -e $STUB/ctrl_udp_fake ]]; then echo '"198.18.0.7"'; fi
exit 0
STUB
chmod +x "$LTS"/*
lt() { # mode, then switches to create; prints the result lines and the labelled SKIP/PASS/FAIL tags
  STUB=$(mktemp -d); mkdir -p "$STUB/db" "$STUB/run"; export STUB
  echo "$1" > "$STUB/db/mode"; shift
  touch "$STUB/enabled"; echo 'block drop quick all label "tunlock-x"' > "$STUB/anchor"
  local f; for f in "$@"; do touch "$STUB/$f"; done
  TUNLOCK_TEST_PATH=$LTS TUNLOCK_CONF=$F/good.conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run \
    $T test 2>&1 | awk '/^(PASS|FAIL|SKIP|INFO) +direct|^(PASS|FAIL|SKIP|INFO) +IPv6|^UNCONFIRMED=|^RESULT=/ { print ($1 ~ /^UNCONFIRMED=/ ? $0 : $1) }' | paste -sd' ' -
}
expect_eq "leak test: IPv6 without a reference run on this network stays unconfirmed" \
  "$(lt protected ctrl4 ctrl_udp has6 v6gw)" "PASS PASS SKIP SKIP UNCONFIRMED=ipv6 RESULT=pass"
expect_eq "leak test: no IPv6 on the network says IPv6 blocking is unconfirmed" \
  "$(lt protected ctrl4 ctrl_udp)" "PASS PASS SKIP UNCONFIRMED=ipv6 RESULT=pass"
expect_eq "leak test: IPv4 without an answer through the tunnel is not proof: incomplete" \
  "$(lt protected ctrl_udp)" "SKIP PASS SKIP UNCONFIRMED=ipv4 ipv6 RESULT=incomplete"
expect_eq "leak test: no UDP through the tunnel leaves UDP unconfirmed" \
  "$(lt protected ctrl4)" "PASS SKIP SKIP UNCONFIRMED=udp ipv6 RESULT=pass"
expect_eq "leak test: a DNS answer that is not from 1.1.1.1 does not confirm UDP blocking" \
  "$(lt protected ctrl4 ctrl_udp_fake)" "PASS SKIP SKIP UNCONFIRMED=udp ipv6 RESULT=pass"
expect_eq "leak test: a timed-out UDP control is a SKIP and the test goes on" \
  "$(lt protected ctrl4 dig_timeout has6 v6gw)" "PASS SKIP SKIP SKIP UNCONFIRMED=udp ipv6 RESULT=pass"
expect_eq "leak test: DNS timing out everywhere does not end the test" \
  "$(lt protected ctrl4 dig_timeout_all)" "PASS SKIP SKIP UNCONFIRMED=udp ipv6 RESULT=pass"
expect_eq "leak test: a direct answer is a leak whatever the control says" \
  "$(lt protected ctrl_udp direct4 has6 v6gw direct6)" "FAIL PASS FAIL SKIP UNCONFIRMED=ipv6 RESULT=fail"
# A direct reference run on this network makes IPv6 provable.
STUB_KEEP=$(mktemp -d)
lt_chain() { # mode switches...: like lt, on one persistent state dir
  local mode=$1; shift
  STUB=$STUB_KEEP; mkdir -p "$STUB/db" "$STUB/run"; export STUB
  rm -f "$STUB"/direct6 "$STUB"/route6; echo "$mode" > "$STUB/db/mode"
  touch "$STUB/enabled"; echo 'block drop quick all label "tunlock-x"' > "$STUB/anchor"
  local f; for f in "$@"; do touch "$STUB/$f"; done
  TUNLOCK_TEST_PATH=$LTS TUNLOCK_CONF=$F/good.conf TUNLOCK_STATE_DIR=$STUB/db TUNLOCK_RUN_DIR=$STUB/run \
    $T test 2>&1 | awk '/^(PASS|FAIL|SKIP|INFO) +direct|^(PASS|FAIL|SKIP|INFO) +IPv6|^UNCONFIRMED=|^RESULT=/ { print ($1 ~ /^UNCONFIRMED=/ ? $0 : $1) }' | paste -sd' ' -
}
expect_eq "leak test: the direct run is reference only and saves the IPv6 baseline" \
  "$(lt_chain direct ctrl4 ctrl_udp has6 v6gw direct6 route6) $(awk '{ print $1, $2 }' "$STUB_KEEP/db/ipv6-baseline")" \
  "INFO INFO INFO INFO RESULT=baseline en0|fe80::1%en0|aa:bb:cc:00:00:01|2001:db8:0:0 1"
expect_eq "leak test: after that reference, no IPv6 answer counts as blocked" \
  "$(lt_chain protected ctrl4 ctrl_udp has6 v6gw)" "PASS PASS PASS PASS UNCONFIRMED= RESULT=pass"
expect_eq "leak test: another network behind the same router address gets no reference" \
  "$(lt_chain protected ctrl4 ctrl_udp has6 v6gw mac2; rm -f "$STUB_KEEP/mac2")" "PASS PASS SKIP SKIP UNCONFIRMED=ipv6 RESULT=pass"
awk '{ $3 = $3 - 90000; print }' "$STUB_KEEP/db/ipv6-baseline" > "$STUB_KEEP/b" && mv "$STUB_KEEP/b" "$STUB_KEEP/db/ipv6-baseline"
expect_eq "leak test: a reference older than a day proves nothing" \
  "$(lt_chain protected ctrl4 ctrl_udp has6 v6gw)" "PASS PASS SKIP SKIP UNCONFIRMED=ipv6 RESULT=pass"
rm -rf "$STUB_KEEP" "$LTS"

# The app's config model (Swift), when a Swift compiler is around.
if command -v swiftc >/dev/null; then
  while IFS= read -r line; do
    case $line in "ok   "*) ok "${line#ok   }" ;; "FAIL "*) ko "${line#FAIL }" ;; *) [[ -z $line ]] || ko "swift build: $line" ;; esac
  done < <(tests/swift-model.sh 2>&1)
else echo "skip swift model tests (no swiftc)"; fi

echo "$pass passed, $fail failed"
(( fail == 0 ))
