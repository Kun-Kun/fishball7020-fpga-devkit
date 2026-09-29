#!/usr/bin/env bash
# Record, check or clear the operator's affirmation that the TX port is safe to key.
#
#   ./devkit tx-affirm "20 dB pad to RX1"   record it, for this boot only
#   ./devkit tx-affirm --check              exit 0 only if one is on record
#   ./devkit tx-affirm --show               what is on record
#   ./devkit tx-affirm --clear              withdraw it
#
# WHY THIS EXISTS, AND WHAT IT CANNOT DO.
#
# This board has no directional coupler and no detector on the transmit port, so
# whether anything is attached to it CANNOT BE MEASURED. Not by this script, not
# by any other. An unterminated SMA and a 20 dB pad look identical to the chip.
#
# So the only thing that can be recorded is what a person says is attached, and
# the only honest thing to do with it is make it explicit, make it expire, and
# refuse without it. That is all this is. It does not detect anything.
#
# IT DOES NOT SURVIVE A REBOOT, by construction rather than by policy: the record
# lives in /run on the board, which is a tmpfs. A board that has been power-cycled
# has no affirmation, because the thing holding it ceased to exist. The boot id is
# recorded inside it as well, so even a /run that somebody made persistent is
# still rejected after a reboot.
#
# THERE IS NO DEFAULT AND NO "YES" FLAG. An absent record is a refusal.
#
# WHAT IT DOES NOT COVER: any libiio client can write out_voltageN_hardwaregain
# directly, and nothing here can stop it. This gates the devkit's own
# TX-enabling paths. It shrinks the window; it does not close it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REC=/run/fishball/tx-affirmed

# Prefer the ssh alias that ./devkit ssh-key writes, because it carries the USER
# and the key. Going straight to the address logs in as whoever you are on this
# machine, and the board wants root - which fails as "Permission denied" and
# looks like the board is unreachable.
ALIAS="${FISHBALL_SSH_ALIAS:-fishball}"
board() { python3 "$HERE/tools/board_addr.py" 2>/dev/null || echo fishball.local; }
target() {
    if ssh -G "$ALIAS" 2>/dev/null | grep -qi "^hostname .\+"; then
        grep -qi "^Host $ALIAS\$" "$HOME/.ssh/config" 2>/dev/null && { echo "$ALIAS"; return; }
    fi
    echo "root@$(board)"
}
on_board() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$(target)" "$@" 2>/dev/null; }

usage() { sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
    --check)
        rec="$(on_board "cat $REC" 2>/dev/null)" || true
        [ -n "$rec" ] || { echo "no TX affirmation on record for this boot." >&2
            echo "  Nothing on this board can sense what is attached to the TX port." >&2
            echo "  Say what is on it, then retry:" >&2
            echo "      ./devkit tx-affirm \"20 dB pad to RX1\"" >&2
            exit 1; }
        # A record that outlived its boot is not a record.
        want="$(on_board 'cat /proc/sys/kernel/random/boot_id')"
        have="$(printf '%s\n' "$rec" | sed -n 's/^boot=//p')"
        if [ -n "$want" ] && [ -n "$have" ] && [ "$want" != "$have" ]; then
            echo "the affirmation on record is from a previous boot - refusing." >&2
            exit 1
        fi
        exit 0 ;;
    --show)
        rec="$(on_board "cat $REC")" || true
        [ -n "$rec" ] && printf '%s\n' "$rec" || { echo "nothing on record for this boot."; exit 1; } ;;
    --clear)
        on_board "rm -f $REC" && echo "affirmation withdrawn." ;;
    -h|--help|"") usage ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)
        what="$*"
        # Build the record HERE and pipe it, rather than opening a heredoc on the
        # far side of an ssh argument - the nesting does not survive the quoting,
        # and it fails by writing nothing while looking like it worked.
        boot="$(on_board 'cat /proc/sys/kernel/random/boot_id')"
        [ -n "$boot" ] || { echo "could not reach the board." >&2; exit 1; }
        printf 'what=%s\nwho=%s@%s\nwhen=%s\nboot=%s\n' \
            "$what" "${USER:-unknown}" "$(hostname)" "$(date -Is)" "$boot" \
        | on_board "mkdir -p /run/fishball && cat > $REC" \
        || { echo "could not write the record to the board." >&2; exit 1; }
        echo "recorded: $what"
        echo "  valid until this board reboots, and no longer." ;;
esac
