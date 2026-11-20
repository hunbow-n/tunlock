#!/bin/bash
# Builds and runs tests/config_model.swift against the app's model sources.
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
S=app/Sources/Tunlock
swiftc -swift-version 5 -parse-as-library ${FLAGS[@]+"${FLAGS[@]}"} -framework SystemConfiguration \
  "$S/Backend.swift" "$S/L10n.swift" "$S/Net.swift" tests/config_model.swift -o "$TMP/model" 2>&1 | grep -E 'error' || true
"$TMP/model"
