#!/bin/bash
# Install tunlock: root guard (LaunchDaemon) + per-user SSH keeper (LaunchAgent).
# Usage: sudo ./install.sh [--sudoers] [--user NAME]
#   --sudoers  let the user switch modes and run the leak test without a password
#              (without it, an existing passwordless entry is removed)
#   --user     account that owns the SSH key (default: the one that ran sudo)
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
PREFIX=/usr/local
SRC=$(cd "$(dirname "$0")" && pwd -P)
die() { echo "install: $*" >&2; exit 1; }
# Reload a launchd job. bootout returns before launchd has dropped the job, and
# a bootstrap in that window fails with "Bootstrap failed: 5" (#37): wait it out.
reload_job() { # domain, label, plist
  local n=0
  launchctl bootout "$1/$2" 2>/dev/null || true
  while launchctl print "$1/$2" >/dev/null 2>&1 && (( n++ < 50 )); do sleep 0.1; done
  launchctl bootstrap "$1" "$3" || die "$2 did not start; the config is saved, run the installer again"
}

[[ $EUID == 0 ]] || die "run with sudo"
USER_NAME=${SUDO_USER:-}
SUDOERS=0
while (( $# )); do
  case $1 in
    --sudoers) SUDOERS=1 ;;
    --user) USER_NAME=${2:-}; shift ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
[[ $USER_NAME =~ ^[A-Za-z_][A-Za-z0-9._-]*$ && $USER_NAME != root ]] || die "run with sudo from your own account, or pass --user"
USER_UID=$(id -u "$USER_NAME") || die "no such user $USER_NAME"
USER_HOME=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{ print $2 }')

# The guard runs as root, so its code and config must not be replaceable by
# a user process. On Intel Macs Homebrew often owns /usr/local/*: refuse.
root_only_path() {
  local p=$1
  while [[ -n $p && $p != / ]]; do
    if [[ -e $p ]]; then
      [[ $(stat -f %u "$p") == 0 ]] || die "$p is not owned by root; install would let user processes replace root code"
      [[ $(( 0$(stat -f %Lp "$p") & 022 )) == 0 ]] || die "$p is group/world writable"
    fi
    p=$(dirname "$p")
  done
}
root_only_path "$PREFIX/libexec/tunlock"
root_only_path "$PREFIX/etc"

install -d -o root -g wheel -m 755 "$PREFIX/libexec/tunlock" "$PREFIX/etc" "$PREFIX/bin"
install -o root -g wheel -m 755 "$SRC/bin/tunlock" "$PREFIX/libexec/tunlock/tunlock"
# Optional sleep helper (built by build-app.sh): closes the tunnel before sleep.
if [[ -x $SRC/bin/tunlock-sleepwatch ]]; then
  install -o root -g wheel -m 755 "$SRC/bin/tunlock-sleepwatch" "$PREFIX/libexec/tunlock/tunlock-sleepwatch"
fi
ln -sfn "$PREFIX/libexec/tunlock/tunlock" "$PREFIX/bin/tunlock"

CONF=$PREFIX/etc/tunlock.conf
if [[ ! -e $CONF ]]; then
  install -o root -g wheel -m 644 "$SRC/tunlock.conf.example" "$CONF"
  echo "Created $CONF. Edit it (sudo), then run this installer again."
  exit 0
fi
"$PREFIX/libexec/tunlock/tunlock" render-rules block >/dev/null || die "fix $CONF first"
if grep -Eq '^VPS_IP=(192\.0\.2|198\.51\.100|203\.0\.113)\.' "$CONF"; then
  die "$CONF still has the example VPS_IP"
fi
chown root:wheel "$CONF"
chmod 644 "$CONF"

# Root guard: owns pf. Mode starts as direct unless one was chosen before.
install -d -o root -g wheel -m 755 /var/db/tunlock
[[ -e /var/db/tunlock/mode ]] || echo direct > /var/db/tunlock/mode
sed "s|@PREFIX@|$PREFIX|g" "$SRC/launchd/tunlock.guard.plist" > /Library/LaunchDaemons/tunlock.guard.plist
chown root:wheel /Library/LaunchDaemons/tunlock.guard.plist
chmod 644 /Library/LaunchDaemons/tunlock.guard.plist
reload_job system tunlock.guard /Library/LaunchDaemons/tunlock.guard.plist

# SSH keeper runs as the user, with the user's keys and known_hosts.
AGENT=$USER_HOME/Library/LaunchAgents/tunlock.ssh.plist
# Everything under the user's home is written as that user, never as root:
# a planted symlink there can then only reach files the user already owns.
as_user() { sudo -u "$USER_NAME" -- "$@"; }
as_user /bin/mkdir -p "$USER_HOME/Library/LaunchAgents" "$USER_HOME/Library/Logs"
# shellcheck disable=SC2016  # $1 expands in the user shell
sed -e "s|@PREFIX@|$PREFIX|g" -e "s|@HOME@|$USER_HOME|g" "$SRC/launchd/tunlock.ssh.plist" \
  | as_user /bin/sh -c 'umask 022; cat > "$1.tmp" && mv -f "$1.tmp" "$1"' sh "$AGENT"
reload_job "gui/$USER_UID" tunlock.ssh "$AGENT"

if (( SUDOERS )); then
  tmp=$(mktemp)
  cli=$PREFIX/libexec/tunlock/tunlock
  echo "$USER_NAME ALL=(root) NOPASSWD: $cli protect, $cli direct, $cli on, $cli off, $cli test" > "$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "sudoers entry rejected"; }
  install -o root -g wheel -m 440 "$tmp" /etc/sudoers.d/tunlock
  rm -f "$tmp"
else
  rm -f /etc/sudoers.d/tunlock
fi

echo "Installed. Mode: $(cat /var/db/tunlock/mode). Next:"
echo "  tunlock doctor     check SSH, TUN and pf"
echo "  tunlock protect    turn the kill switch on"
