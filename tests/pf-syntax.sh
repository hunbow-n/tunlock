#!/bin/bash
# Asks pfctl to parse (-n: never load) every generated rule set, including a
# cascade and exceptions. The only test meant for sudo; it changes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $EUID == 0 ]] || { echo "run with sudo: pfctl needs root even to parse" >&2; exit 1; }
conf=$(mktemp)
trap 'rm -f "$conf"' EXIT
{
  cat tests/fixtures/good.conf
  echo 'BYPASS_NETS="192.168.0.0/24"'
  echo 'BYPASS_DNS="corp.example=172.16.5.2"'
  echo 'JUMP_HOST=198.51.100.7'
} > "$conf"
fail=0
for c in tests/fixtures/good.conf "$conf" ${1:+"$1"}; do
  for phase in block probe open; do
    if out=$(TUNLOCK_CONF=$c bin/tunlock render-rules "$phase" utun7 en0 | pfctl -nf - 2>&1); then
      echo "ok   pfctl parses $phase ($c)"
    else
      echo "FAIL pfctl parses $phase ($c)"; echo "$out"; fail=1
    fi
  done
done
exit "$fail"
