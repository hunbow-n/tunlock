#!/bin/bash
# Download the pinned sing-box release for macOS, check it against the pinned
# SHA-256 and write a universal binary plus its license to <out-dir>.
# Usage: tools/fetch-sing-box.sh <out-dir>
# SING_BOX_CACHE=<dir> takes the release archives from there when present.
# sing-box is GPLv3 and runs as a separate program: Tunlock ships its unmodified
# binary, its license and a link to the source of exactly this version.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

SING_BOX_VERSION=1.14.4
sha256() { # release arch -> pinned SHA-256 of its archive
  case $1 in
    arm64) echo 0d8c7f5ed5d587b0f1a5e9772a708ec3bfa4ac4c9329604b01d8d9c2ba406838 ;;
    amd64) echo eae86b9b033bba50b7c44ab719e4bfac0aca05efd28483390ed3aa510f32db25 ;;
  esac
}
BASE=https://github.com/SagerNet/sing-box/releases/download/v$SING_BOX_VERSION
SOURCE=https://github.com/SagerNet/sing-box/tree/v$SING_BOX_VERSION

die() { echo "fetch-sing-box: $*" >&2; exit 1; }
out=${1:-}
[[ -n $out ]] || die "usage: $0 <out-dir>"
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for arch in arm64 amd64; do
  name=sing-box-$SING_BOX_VERSION-darwin-$arch
  if [[ -n ${SING_BOX_CACHE:-} && -f $SING_BOX_CACHE/$name.tar.gz ]]; then cp "$SING_BOX_CACHE/$name.tar.gz" "$work/"
  else curl -fsSL --retry 3 --retry-all-errors -o "$work/$name.tar.gz" "$BASE/$name.tar.gz" || die "download failed: $name"
  fi
  want=$(sha256 "$arch")
  got=$(shasum -a 256 "$work/$name.tar.gz" | awk '{ print $1 }')
  [[ $got == "$want" ]] || die "$name: SHA-256 $got, expected $want"
  mkdir -p "$work/$arch"
  tar -xzf "$work/$name.tar.gz" -C "$work/$arch" "$name/sing-box" "$name/LICENSE"
done

lipo -create "$work/arm64/sing-box-$SING_BOX_VERSION-darwin-arm64/sing-box" \
  "$work/amd64/sing-box-$SING_BOX_VERSION-darwin-amd64/sing-box" -output "$out/sing-box"
chmod 755 "$out/sing-box"
cp "$work/arm64/sing-box-$SING_BOX_VERSION-darwin-arm64/LICENSE" "$out/sing-box.LICENSE"
cat > "$out/sing-box.NOTICE" <<EOF
sing-box $SING_BOX_VERSION, unmodified release binaries for darwin-arm64 and
darwin-amd64 joined into one universal file. License: GPLv3 or later (see
sing-box.LICENSE). Source code of this version: $SOURCE
EOF
echo "sing-box $SING_BOX_VERSION -> $out/sing-box"
