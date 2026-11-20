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
swiftc -swift-version 5 -parse-as-library "${FLAGS[@]}" -framework SystemConfiguration -framework ServiceManagement \
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
cat tests/fixtures/good.conf tests/fixtures/cascade.extra > "$TMP/conf"
rm -f docs/screenshots/*.png
for lang in en ru; do
  for theme in light dark; do
    env "$( [[ $theme == dark ]] && echo DARK=1 || echo LIGHT=1 )" TUNLOCK_UI_STATE="$TMP/state" TUNLOCK_UI_DAEMON="$TMP/daemon" TUNLOCK_UI_CONFIG="$TMP/conf" \
      "$TMP/snap" "docs/screenshots/$lang-$theme" -AppleLanguages "($lang)"
  done
done
echo "Wrote docs/screenshots"
