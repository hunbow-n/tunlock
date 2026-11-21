#!/bin/bash
# Builds build/Tunlock.app: the menu bar app with the backend scripts inside.
# Needs Xcode or the Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
OUT=$ROOT/build
APP=$OUT/Tunlock.app
VERSION=${TUNLOCK_BUILD_VERSION:-$(awk -F= '$1 == "VERSION" { print $2; exit }' bin/tunlock)}
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid Tunlock build version: $VERSION" >&2
  exit 1
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Command Line Tools 16.x ship a duplicate SwiftBridging module map that
# breaks every Foundation import. Hide it for this build only.
FLAGS=()
CLT_MAP=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ $(xcode-select -p) == /Library/Developer/CommandLineTools && -s $CLT_MAP ]]; then
  : > "$TMP/empty.modulemap"
  cat > "$TMP/overlay.yaml" <<YAML
{"version":0,"case-sensitive":"false","roots":[{"type":"directory","name":"${CLT_MAP%/*}","contents":[{"type":"file","name":"module.modulemap","external-contents":"$TMP/empty.modulemap"}]}]}
YAML
  FLAGS=(-vfsoverlay "$TMP/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$TMP/overlay.yaml")
fi

compile() { # arch
  swiftc -O -swift-version 5 -parse-as-library -target "$1-apple-macos13.0" ${FLAGS[@]+"${FLAGS[@]}"} \
    -framework SystemConfiguration -framework ServiceManagement -framework UserNotifications \
    app/Sources/Tunlock/*.swift -o "$TMP/Tunlock-$1"
}
echo "Compiling Tunlock ${VERSION}..."
compile arm64
compile x86_64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/backend/bin" "$APP/Contents/Resources/backend/launchd"
lipo -create "$TMP/Tunlock-arm64" "$TMP/Tunlock-x86_64" -output "$APP/Contents/MacOS/Tunlock"
# The guard's sleep helper (IOKit): closes the tunnel before the Mac sleeps.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" ${FLAGS[@]+"${FLAGS[@]}"} -framework IOKit \
    app/Helpers/SleepWatch.swift -o "$TMP/sleepwatch-$arch"
done
sed "s/@VERSION@/$VERSION/g" app/Info.plist > "$APP/Contents/Info.plist"
cp app/Resources/AppIcon.icns "$APP/Contents/Resources/"
B=$APP/Contents/Resources/backend
sed "s/^VERSION=.*/VERSION=$VERSION/" bin/tunlock > "$B/bin/tunlock"
lipo -create "$TMP/sleepwatch-arm64" "$TMP/sleepwatch-x86_64" -output "$B/bin/tunlock-sleepwatch"
cp install.sh uninstall.sh tunlock.conf.example "$B/"
cp launchd/*.plist "$B/launchd/"
chmod 755 "$B/bin/tunlock" "$B/bin/tunlock-sleepwatch" "$B/install.sh" "$B/uninstall.sh"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
echo "Install: cp -R \"$APP\" /Applications/ && open /Applications/Tunlock.app"
