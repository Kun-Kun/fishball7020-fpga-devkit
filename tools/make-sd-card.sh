#!/usr/bin/env bash
# Write a bootable Fishball7020 SD card from a set of firmware files.
#
# Why this exists: every recovery path in these docs ends with "use a card
# reader", and until now there was nothing that made the card. It is also how
# you test a BOOT.bin without risking the card the board currently boots from.
#
#   ./tools/make-sd-card.sh /dev/sdX                    # from firmware/output/
#   ./tools/make-sd-card.sh /dev/sdX --boot-bin FILE    # swap in one BOOT.bin
#   ./tools/make-sd-card.sh /dev/sdX --dry-run          # show, touch nothing
#
# It writes the FACTORY layout: one FAT32 partition holding the five files.
# That boots the Buildroot RAM disk and needs no second partition, which makes
# it self-contained and safe to hand to a board whose own card you have removed.
# It is NOT the modern Debian layout (vfat /boot + ext4 /) - see
# firmware-modern/README.md for that one.
#
# THE SAFETY RULES, because this command can destroy the wrong disk:
#   - the target must be a whole disk, not a partition
#   - it must be removable AND on the USB or MMC transport
#   - it must not be the disk holding / or /home
#   - nothing on it may be mounted
#   - it must be no larger than MAX_SIZE_GB, so a backup drive cannot be hit
#   - you must type the device name back to confirm
# Any one of these failing stops the script. There is no --force.
set -euo pipefail

MAX_SIZE_GB="${MAX_SIZE_GB:-256}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${FW_OUTPUT:-$HERE/firmware/output}"
FILES=(BOOT.bin devicetree.dtb uEnv.txt uImage uramdisk.image.gz)

DEV=""; BOOT_BIN=""; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --boot-bin) BOOT_BIN="$2"; shift 2 ;;
        --boot-bin=*) BOOT_BIN="${1#*=}"; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \?//'; exit 0 ;;
        -*) echo "ERROR: unknown option '$1'" >&2; exit 2 ;;
        *) [ -z "$DEV" ] || { echo "ERROR: more than one device given" >&2; exit 2; }
           DEV="$1"; shift ;;
    esac
done
[ -n "$DEV" ] || { echo "ERROR: no device. Try: $(basename "$0") --help" >&2; exit 2; }

die() { echo "REFUSING: $*" >&2; exit 1; }

# ---- identify the target -------------------------------------------------
[ -b "$DEV" ] || die "$DEV is not a block device."
NAME="$(basename "$(readlink -f "$DEV")")"
SYS="/sys/class/block/$NAME"
[ -d "$SYS" ] || die "$DEV has no /sys/class/block entry."
[ -e "$SYS/partition" ] && die "$DEV is a PARTITION. Give the whole disk (e.g. /dev/sdb, not /dev/sdb1)."

removable="$(cat "$SYS/removable" 2>/dev/null || echo 0)"
tran="$(lsblk -dn -o TRAN "$DEV" 2>/dev/null | tr -d ' ')"
size_b="$(cat "$SYS/size")"; size_b=$(( size_b * 512 ))
size_gb=$(( size_b / 1000000000 ))

[ "$removable" = "1" ] || die "$DEV is not removable. This is meant for a card reader."
case "$tran" in usb|mmc) ;; *) die "$DEV is on transport '${tran:-unknown}', not usb/mmc." ;; esac
[ "$size_b" -gt 0 ] || die "$DEV reports zero size - is a card actually inserted?"
[ "$size_gb" -le "$MAX_SIZE_GB" ] || die "$DEV is ${size_gb} GB, over the ${MAX_SIZE_GB} GB limit. That looks like a drive, not a card."

# Never the disk we are running from.
for mp in / /home; do
    hold="$(findmnt -no SOURCE "$mp" 2>/dev/null || true)"
    [ -n "$hold" ] || continue
    holdname="$(basename "$(readlink -f "$hold")")"
    case "$holdname" in "$NAME"*) die "$DEV holds $mp." ;; esac
done

mounted="$(lsblk -nr -o MOUNTPOINT "$DEV" | grep -v '^$' || true)"
[ -z "$mounted" ] || die "something on $DEV is mounted:
$(echo "$mounted" | sed 's/^/    /')
  Unmount it first."

# ---- check the payload ---------------------------------------------------
[ -d "$SRC_DIR" ] || die "$SRC_DIR does not exist. Build first, or set FW_OUTPUT."
for f in "${FILES[@]}"; do
    [ -s "$SRC_DIR/$f" ] || die "$SRC_DIR/$f is missing or empty."
done
if [ -n "$BOOT_BIN" ]; then
    [ -s "$BOOT_BIN" ] || die "--boot-bin $BOOT_BIN is missing or empty."
fi

echo "About to ERASE and rewrite:"
lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL "$DEV" | sed 's/^/    /'
echo
echo "Writing the factory layout - one FAT32 partition - with:"
for f in "${FILES[@]}"; do
    src="$SRC_DIR/$f"; note=""
    if [ "$f" = "BOOT.bin" ] && [ -n "$BOOT_BIN" ]; then src="$BOOT_BIN"; note="   <-- SUBSTITUTED"; fi
    printf '    %-20s %9s bytes  %s%s\n' "$f" "$(stat -c %s "$src")" "$(md5sum "$src" | cut -c1-12)" "$note"
    [ "$f" = "BOOT.bin" ] && [ -n "$BOOT_BIN" ] && printf '    %-20s %s\n' "" "from $BOOT_BIN"
done
echo

if [ "$DRY" = "1" ]; then echo "--dry-run: nothing written."; exit 0; fi

printf 'Type the device name (%s) to confirm, anything else aborts: ' "$DEV"
read -r answer
[ "$answer" = "$DEV" ] || { echo "Aborted."; exit 1; }

# ---- write ---------------------------------------------------------------
echo "=== Partitioning ==="
# A single primary FAT32 (type 0c, LBA) starting at 2048, which is what the
# Zynq BootROM expects to find a FAT filesystem in.
sudo wipefs -a "$DEV" >/dev/null
printf 'label: dos\nstart=2048, type=0c, bootable\n' | sudo sfdisk "$DEV" >/dev/null
sudo partprobe "$DEV" 2>/dev/null || true
sleep 2

PART="${DEV}1"; [ -b "$PART" ] || PART="${DEV}p1"
[ -b "$PART" ] || die "cannot find the new partition (tried ${DEV}1 and ${DEV}p1)."

echo "=== Formatting $PART as FAT32 ==="
sudo mkfs.vfat -F 32 -n FISHBALL "$PART" >/dev/null

MNT="$(mktemp -d)"
cleanup() { sudo umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
sudo mount "$PART" "$MNT"

echo "=== Copying ==="
for f in "${FILES[@]}"; do
    src="$SRC_DIR/$f"
    [ "$f" = "BOOT.bin" ] && [ -n "$BOOT_BIN" ] && src="$BOOT_BIN"
    sudo cp "$src" "$MNT/$f"
    printf '    %-20s %9s bytes\n' "$f" "$(stat -c %s "$MNT/$f")"
done
sudo sync

echo "=== Verifying (re-reading what landed on the card) ==="
fail=0
for f in "${FILES[@]}"; do
    src="$SRC_DIR/$f"
    [ "$f" = "BOOT.bin" ] && [ -n "$BOOT_BIN" ] && src="$BOOT_BIN"
    a="$(md5sum "$src" | cut -d' ' -f1)"
    b="$(sudo md5sum "$MNT/$f" | cut -d' ' -f1)"
    if [ "$a" = "$b" ]; then printf '    ok    %-20s %s\n' "$f" "$a"
    else printf '    FAIL  %-20s %s != %s\n' "$f" "$a" "$b"; fail=1; fi
done
cleanup; trap - EXIT
[ "$fail" = "0" ] || { echo "ERROR: the card does not match the source. Do not boot it." >&2; exit 1; }

echo
echo "Done. $DEV holds a bootable factory card."
echo "Power the board OFF before swapping cards - it does not tolerate a live swap."
