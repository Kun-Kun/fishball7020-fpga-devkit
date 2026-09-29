#!/usr/bin/env bash
# Log into the board without typing a password, in one command.
#
#   ./devkit ssh-key            set it up, then `ssh fishball`
#   ./devkit ssh-key --check    is it already working?
#   ./devkit ssh-key --show     print the public key and stop
#
# WHAT IT DOES, all of it idempotent so running it twice is harmless:
#
#   1. makes ~/.ssh/fishball, an ed25519 key used for NOTHING ELSE
#   2. appends the public half to the board's /root/.ssh/authorized_keys
#   3. adds a `Host fishball` block to ~/.ssh/config, leaving the rest alone
#   4. proves it works with BatchMode=yes, which cannot fall back to a password
#
# WHY A DEDICATED KEY rather than your usual one. This board ships with a
# published root password and sits on whatever network you put it on. Giving it
# your everyday key means a board on a conference wifi is holding a credential
# that opens your other machines. A key used for one board can be deleted
# without consequence.
#
# THE PASSWORD IS LEFT ENABLED, deliberately. Turning it off is one line, and
# it is the line that turns a typo into a card reader: this board has no
# working `systemctl reboot` (see firmware-modern/debian/overlay - logind is
# masked) and no console unless you have the FTDI cable. Add
# PasswordAuthentication no yourself once key login is proven, not before.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${FISHBALL_SSH_KEY:-$HOME/.ssh/fishball}"
ALIAS_NAME="${FISHBALL_SSH_ALIAS:-fishball}"
BOARD_PASS="${BOARD_PASS:-analog}"

board() {
    if [ -n "${BOARD:-}" ]; then printf '%s\n' "$BOARD"; return; fi
    python3 "$HERE/tools/board_addr.py" 2>/dev/null || echo fishball.local
}

check() {
    ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        -i "$KEY" "root@$1" true 2>/dev/null
}

case "${1:-setup}" in
--show)
    [ -r "$KEY.pub" ] || { echo "no key at $KEY.pub - run ./devkit ssh-key" >&2; exit 1; }
    cat "$KEY.pub"; exit 0 ;;
--check)
    H=$(board)
    if [ -r "$KEY" ] && check "$H"; then
        echo "OK  key login works: ssh $ALIAS_NAME   (or ssh -i $KEY root@$H)"; exit 0
    fi
    echo "not set up yet - run ./devkit ssh-key"; exit 1 ;;
-h|--help|help)
    sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

HOST=$(board)
echo "  board: $HOST"

if [ -r "$KEY" ] && check "$HOST"; then
    echo "  already working - nothing to do."
    echo
    echo "      ssh $ALIAS_NAME"
    exit 0
fi

# 1 - the key
if [ ! -r "$KEY" ]; then
    mkdir -p "$(dirname "$KEY")"; chmod 700 "$(dirname "$KEY")"
    ssh-keygen -t ed25519 -f "$KEY" -N "" -q \
        -C "fishball7020 devkit $(date +%F)"
    echo "  made $KEY (no passphrase - see --help)"
else
    echo "  using the key already at $KEY"
fi

# 2 - install it. sshpass only for this one step; after it, the password is
#     not needed again.
if ! command -v sshpass >/dev/null 2>&1; then
    cat >&2 <<MSG

  sshpass is not installed, so this cannot log in with the password for you.
  Either install it (apt install sshpass) or copy the key across by hand:

      ssh-copy-id -i $KEY.pub root@$HOST

MSG
    exit 1
fi

PUB=$(cat "$KEY.pub")
sshpass -p "$BOARD_PASS" ssh -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 "root@$HOST" \
    "mkdir -p /root/.ssh && chmod 700 /root/.ssh
     grep -qxF '$PUB' /root/.ssh/authorized_keys 2>/dev/null || \
         printf '%s\n' '$PUB' >> /root/.ssh/authorized_keys
     chmod 600 /root/.ssh/authorized_keys
     chown -R root:root /root/.ssh"
echo "  installed on the board"

# 3 - the shorthand
CFG="$HOME/.ssh/config"
touch "$CFG"; chmod 600 "$CFG"
if ! grep -qE "^Host[[:space:]]+$ALIAS_NAME\$" "$CFG"; then
    cat >> "$CFG" <<CFGEOF

# Fishball7020 SDR - added by ./devkit ssh-key
Host $ALIAS_NAME
    HostName $HOST
    User root
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
CFGEOF
    echo "  added 'Host $ALIAS_NAME' to $CFG"
else
    echo "  'Host $ALIAS_NAME' already in $CFG - left alone"
fi

# 4 - prove it, without a password being possible
if check "$HOST"; then
    echo
    echo "  OK - key login works."
    echo
    echo "      ssh $ALIAS_NAME"
    echo "      ssh $ALIAS_NAME reboot"
    echo "      scp capture.iq $ALIAS_NAME:/tmp/"
else
    echo >&2
    echo "  The key was installed but BatchMode login still failed." >&2
    echo "  Check the board's sshd allows it:  sshd -T | grep pubkey" >&2
    exit 1
fi
