#!/bin/bash
# Renders docs/screenshots/*.png from the real views with sample state.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FLAGS=()
CLT_MAP=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ $(xcode-select -p) == /Library/Developer/CommandLineTools && -s $CLT_MAP ]]; then
  : > "$TMP/empty.modulemap"
  printf '{"version":0,"case-sensitive":"false","roots":[{"type":"directory","name":"%s","contents":[{"type":"file","name":"module.modulemap","external-contents":"%s"}]}]}' \
    "${CLT_MAP%/*}" "$TMP/empty.modulemap" > "$TMP/overlay.yaml"
  FLAGS=(-vfsoverlay "$TMP/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$TMP/overlay.yaml")
fi
srcs=()
for f in app/Sources/Tunlock/*.swift; do [[ $f == */TunlockApp.swift ]] || srcs+=("$f"); done
swiftc -swift-version 5 -parse-as-library "${FLAGS[@]}" -framework SystemConfiguration -framework ServiceManagement -framework UserNotifications \
  "${srcs[@]}" tools/snapshot.swift -o "$TMP/snap"
mkdir -p docs/screenshots
now=$(date +%s)
cat > "$TMP/state" <<S
updated=$now
mode=protected
phase=open
tun=utun6
ssh=up
ssh_endpoint=127.0.0.1:10800
egress_ip=203.0.113.10
egress_ok=1
egress_at=$((now - 12))
egress_country=NL
phys=en0
expected=203.0.113.10
pf_enabled=1
pf_rules=7
pf_anchor=com.apple/000.tunlock
pf_reachable=1
entry=198.51.100.7:22
entry_up=up
cascade=1
bypass=192.168.0.0/24
error=
S
: > "$TMP/daemon"
{ cat tests/fixtures/good.conf tests/fixtures/cascade.extra; echo EXPECTED_COUNTRY=NL; } > "$TMP/conf"
# Proxy mode: no server, the TUN app talks to a proxy directly.
sed -e 's/^cascade=1$/cascade=0\nupstream=proxy/' -e 's/^entry=.*/entry=198.51.100.20:8080/' \
  -e 's/^egress_ip=.*/egress_ip=198.51.100.20/' -e 's/^expected=.*/expected=198.51.100.20/' \
  -e 's/^egress_country=.*/egress_country=US/' -e 's/^ssh=up$/ssh=none/' "$TMP/state" > "$TMP/state-proxy"
printf 'UPSTREAM=proxy\nPROXY_HOST=198.51.100.20\nPROXY_PORT=8080\nTUN_ADDR=10.20.0.1\nTUN_MASK=0xfffffffc\nTUN_SERVICE="Karing"\n' > "$TMP/conf-proxy"
# A short guard log for the Activity tab.
t0=$(( $(date +%s) - 3600 ))
logt() { date -r $(( t0 + $1 )) '+%Y-%m-%d %H:%M:%S'; }
{
  echo "$(logt 0) guard 0.1.0 started, mode protected"
  echo "$(logt 2) protected mode armed, existing connections reset"
  echo "$(logt 4) tun: none -> utun6"
  echo "$(logt 9) egress verified: 203.0.113.10 (NL) via utun6"
  echo "$(logt 1800) woke after 1240s: re-verifying egress"
  echo "$(logt 1803) egress check got no answer: tunnel closed until verified"
  echo "$(logt 1811) egress verified: 203.0.113.10 (NL) via utun6"
  echo "$(logt 3300) egress MISMATCH: got 192.0.2.44 (DE), expected 203.0.113.10; tunnel closed"
  echo "$(logt 3420) egress verified: 203.0.113.10 (NL) via utun6"
} > "$TMP/guard.log"
export TUNLOCK_UI_LOG=$TMP/guard.log
export TUNLOCK_UI_EXE=/Applications/Tunlock.app/Contents/MacOS/Tunlock
export TUNLOCK_UI_DRAFT=$TMP/draft.conf
# The exit changed: the menu offers to pin it.
sed -e 's/^egress_ok=1$/egress_ok=0/' -e 's/^egress_ip=.*/egress_ip=192.0.2.44/' -e 's/^egress_country=.*/egress_country=DE/' \
  -e 's/^phase=open$/phase=probe/' "$TMP/state" > "$TMP/state-foreign"
printf 'expected_country=\n' >> "$TMP/state-foreign"
rm -f docs/screenshots/*.png
for lang in en ru; do
  for theme in light dark; do
    sed -i '' -e "s/^updated=.*/updated=$(date +%s)/" "$TMP/state"
    env "$( [[ $theme == dark ]] && echo DARK=1 || echo LIGHT=1 )" TUNLOCK_UI_STATE="$TMP/state" TUNLOCK_UI_DAEMON="$TMP/daemon" TUNLOCK_UI_CONFIG="$TMP/conf" \
      "$TMP/snap" "docs/screenshots/$lang-$theme" -AppleLanguages "($lang)"
  done
  sed -i '' -e "s/^updated=.*/updated=$(date +%s)/" -e "s/^egress_at=.*/egress_at=$(( $(date +%s) - 9 ))/" "$TMP/state-proxy"
  env LIGHT=1 SNAPSHOT_PROXY=1 TUNLOCK_UI_STATE="$TMP/state-proxy" TUNLOCK_UI_DAEMON="$TMP/daemon" TUNLOCK_UI_CONFIG="$TMP/conf-proxy" \
    "$TMP/snap" "docs/screenshots/$lang-proxy" -AppleLanguages "($lang)"
  rm -f "docs/screenshots/$lang-proxy-leaktest.png" "docs/screenshots/$lang-proxy-exit.png" "docs/screenshots/$lang-proxy-activity.png"
  sed -i '' "s/^updated=.*/updated=$(date +%s)/" "$TMP/state-foreign"
  env LIGHT=1 SNAPSHOT_MENU_ONLY=1 TUNLOCK_UI_STATE="$TMP/state-foreign" TUNLOCK_UI_DAEMON="$TMP/daemon" TUNLOCK_UI_CONFIG="$TMP/conf" \
    "$TMP/snap" "docs/screenshots/$lang-foreign" -AppleLanguages "($lang)"
done
echo "Wrote docs/screenshots"
