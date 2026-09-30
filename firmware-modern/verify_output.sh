#!/bin/bash
# Is the modern build sane? The boot files present, BOOT.bin carrying exactly its
# three partitions, and the bitstream in it the one the provenance says.
#
#     # run from: the repo root
#     ./devkit verify --target modern
#     ./devkit verify --target modern --board     # also: is the board running it?
#
# The factory target's verify reads Vivado's timing and utilisation reports. The
# modern target never runs Vivado - its bitstream always comes from an imported
# XSA - so there is nothing of that kind to read, and this checks what can be:
# what went INTO BOOT.bin, read back out of it.
set -euo pipefail
FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$FW_DIR")"
OUT="$FW_DIR/output"
PLUTO="$FW_DIR/boot/hdl"
BOARD_CHECK=0
for a in "$@"; do
    case "$a" in
        --board) BOARD_CHECK=1 ;;
        -h|--help) sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown option '$a'" >&2; exit 1 ;;
    esac
done

fail=0
echo "=== files ==="
for f in BOOT.bin uImage devicetree.dtb uEnv.txt; do
    if [ -s "$OUT/$f" ]; then printf '  ok    %-16s %9s B\n' "$f" "$(stat -c%s "$OUT/$f")"
    else printf '  FAIL  %-16s missing - run ./devkit build --target modern --xsa FILE\n' "$f"; fail=1; fi
done
[ -s "$OUT/debian-rootfs.tar.gz" ] && echo "  ok    debian-rootfs.tar.gz (built separately by debian/build.sh)" \
    || echo "  --    debian-rootfs.tar.gz not built - only needed to write a whole card"
[ "$fail" -eq 0 ] || exit 1

echo "=== BOOT.bin ==="
if [ -r "$PLUTO/system_top.xsa" ]; then
    "$REPO/firmware/scripts/check_bootbin.py" "$OUT/BOOT.bin" --xsa "$PLUTO/system_top.xsa" || fail=1
else
    echo "  (no imported XSA at $PLUTO - checking partitions only)"
    "$REPO/firmware/scripts/check_bootbin.py" "$OUT/BOOT.bin" || fail=1
fi
[ -r "$OUT/xsa-provenance.txt" ] && sed -n '2,6p' "$OUT/xsa-provenance.txt" | sed 's/^/  /'

if [ "$BOARD_CHECK" -eq 1 ]; then
    echo "=== the board ==="
    # The same comparison the factory verify makes: md5 of what is on the card's
    # boot partition against what is here. The only thing that proves the board
    # runs THIS build rather than one that looks like it.
    tgt="${FISHBALL_SSH_ALIAS:-fishball}"
    for f in BOOT.bin uImage devicetree.dtb uEnv.txt; do
        here="$(md5sum "$OUT/$f" | cut -d' ' -f1)"
        there="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$tgt" "md5sum /boot/$f 2>/dev/null" | cut -d' ' -f1)" || there=""
        if [ -z "$there" ]; then printf '  ??    %-16s could not read it from the board\n' "$f"; fail=1
        elif [ "$here" = "$there" ]; then printf '  same  %-16s %s\n' "$f" "$here"
        else printf '  DIFF  %-16s here %s  board %s\n' "$f" "$here" "$there"; fail=1; fi
    done
fi
exit "$fail"
