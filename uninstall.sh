#!/bin/bash
# Remove tunlock. Turns protection off first, so the Mac is not left blocked.
# Usage: sudo ./uninstall.sh [--purge] [--user NAME]
#   --purge  also delete the config
#   --user   account whose SSH agent to remove (default: the one that ran sudo)
#
# Order matters: stop the guard, remove the pf rules and release the pf
# reference, and confirm both. Only then delete files. If pf does not
# confirm, nothing else is deleted: the token and state stay for another run.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
PREFIX=/usr/local
DB_DIR=/var/db/tunlock
RUN_DIR=/var/run/tunlock
DAEMONS=/Library/LaunchDaemons
SUDOERS=/etc/sudoers.d/tunlock
# Tests run this against stubs as a normal user; root never sees these.
if [[ -n ${TUNLOCK_TEST_PATH:-} && $EUID != 0 ]]; then
  PATH=$TUNLOCK_TEST_PATH:$PATH
  PREFIX=$TUNLOCK_TEST_ROOT/prefix DB_DIR=$TUNLOCK_TEST_ROOT/db RUN_DIR=$TUNLOCK_TEST_ROOT/run
  DAEMONS=$TUNLOCK_TEST_ROOT/daemons SUDOERS=$TUNLOCK_TEST_ROOT/sudoers
else
  [[ $EUID == 0 ]] || { echo "run with sudo" >&2; exit 1; }
fi
USER_NAME=${SUDO_USER:-}
PURGE=0
while (( $# )); do
  case $1 in
    --purge) PURGE=1 ;;
    --user) USER_NAME=${2:-}; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -z $USER_NAME || $USER_NAME =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || { echo "bad user" >&2; exit 2; }
CLI=$PREFIX/libexec/tunlock/tunlock
CONF=$PREFIX/etc/tunlock.conf
anchor=com.apple/000.tunlock

stop() {
  echo "tunlock: $*" >&2
  echo "Nothing else was removed. The pf token and state are kept; run this again once pf answers." >&2
  echo "Check: sudo pfctl -a $anchor -sr   Remove rules: sudo pfctl -a $anchor -F rules" >&2
  exit 1
}

# 0. Which anchor? Ask the same parser the guard uses, never a second one.
# Without a config (already purged) the default applies.
if [[ -e $CONF ]]; then
  parser=$CLI
  [[ -x $parser ]] || parser=$(cd "$(dirname "$0")" && pwd -P)/bin/tunlock
  anchor=$(TUNLOCK_CONF=$CONF /bin/bash "$parser" config 2>/dev/null | awk -F= '$1 == "PF_ANCHOR" { print $2 }') || true
  [[ -n $anchor ]] || { anchor=unknown; stop "cannot read PF_ANCHOR from $CONF"; }
fi

# 1. Stop the guard so it cannot load rules again.
if [[ -x $CLI ]]; then "$CLI" direct >/dev/null 2>&1 || true; fi
launchctl bootout system/tunlock.guard 2>/dev/null || true

# 2. Remove the rules and the pf reference, and confirm both.
pfctl -a "$anchor" -F rules >/dev/null 2>&1 || true
live=$(pfctl -a "$anchor" -sr 2>/dev/null) || stop "pf did not answer; its rules may still be loaded"
if grep -q 'label "tunlock-' <<< "$live"; then stop "pf did not remove the tunlock rules"; fi
if [[ -s $RUN_DIR/token ]]; then
  pfctl -X "$(cat "$RUN_DIR/token")" >/dev/null 2>&1 || stop "pf did not release the tunlock reference"
  rm -f "$RUN_DIR/token"
fi

# 3. Confirmed: now remove exception routes, resolver files, jobs and files.
if [[ -x $CLI ]]; then "$CLI" cleanup >/dev/null 2>&1 || true; fi
rm -f "$DAEMONS/tunlock.guard.plist"
if [[ -n $USER_NAME && $USER_NAME != root ]]; then
  launchctl bootout "gui/$(id -u "$USER_NAME")/tunlock.ssh" 2>/dev/null || true
  home=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{ print $2 }')
  # Removed as the user, like it was written.
  sudo -u "$USER_NAME" -- /bin/rm -f "$home/Library/LaunchAgents/tunlock.ssh.plist"
fi
rm -rf "$PREFIX/libexec/tunlock" "$DB_DIR" "$RUN_DIR" "$SUDOERS"
[[ -L $PREFIX/bin/tunlock ]] && rm -f "$PREFIX/bin/tunlock"
(( PURGE )) && rm -f "$PREFIX/etc/tunlock.conf"
echo "tunlock removed. Direct internet is allowed."
