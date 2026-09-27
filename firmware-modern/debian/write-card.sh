#!/bin/bash
# Put the Debian root and the boot files onto an SD card.
#
#     # run from: firmware-modern/debian/
#     sudo ./write-card.sh /dev/sdX
#
# THIS DESTROYS EVERYTHING ON THE TARGET. It refuses any device that is not
# removable, refuses anything with mounted partitions it did not unmount itself,
# and prints what it is about to do first. The one mistake this class of script
# makes is writing to the wrong disk, so it would rather be annoying.
#
# The layout is forced rather than chosen: the Zynq BootROM reads BOOT.bin from a
# FAT partition, so p1 must be FAT and the Debian root goes on p2.
#
#   p1   128 MB  FAT32  BOOT.bin  uImage  devicetree.dtb  uEnv.txt
#                       uramdisk.image.gz   <- kept as a fallback, see below
#   p2   rest    ext4   the Debian root
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW="$(dirname "$HERE")"                      # firmware-modern/
REPO="$(dirname "$FW")"
TAR="$HERE/rootfs.tar"
BOOT_MB=128

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: sudo $0 /dev/sdX"
DEV="$1"
[ "$(id -u)" = 0 ] || die "needs root (it partitions a disk)"
[ -b "$DEV" ] || die "$DEV is not a block device"
[ -f "$TAR" ] || die "$TAR not found - run ./build.sh first"

name=$(basename "$DEV")
[ -e "/sys/block/$name" ] || die "$DEV is a partition, not a disk - pass the whole device"
[ "$(cat "/sys/block/$name/removable")" = "1" ] \
    || die "$DEV is NOT removable. Refusing. This is the check that stops this script eating a system disk."
bytes=$(( $(cat "/sys/block/$name/size") * 512 ))
[ "$bytes" -ge $((1024*1024*1024)) ] || die "$DEV is only $((bytes/1024/1024)) MB; a Debian root needs ~1 GB minimum"

# The kernel and device tree come from firmware-modern.
UIMG="$FW/output/uImage"
DTB="$FW/output/devicetree.dtb"
for f in "$UIMG" "$DTB"; do [ -f "$f" ] || die "missing $f - build the modern kernel first"; done

# output/ is a copy, and a copy can be stale. This caught me once: the kernel was
# rebuilt with the systemd options in src/linux and never copied over, so the card
# got a kernel with no CONFIG_NAMESPACES - which boots systemd perfectly and makes
# every unit sandbox silently do nothing. Compare rather than hope.
for pair in "arch/arm/boot/uImage:$UIMG" \
            "arch/arm/boot/dts/xilinx/zynq-pluto-sdr-fishball.dtb:$DTB"; do
    src="$FW/src/linux/${pair%%:*}"; dst="${pair##*:}"
    [ -f "$src" ] || continue
    if ! cmp -s "$src" "$dst"; then
        echo "WARNING: $(basename "$dst") in output/ differs from the one just built:" >&2
        echo "           built   $(md5sum "$src" | cut -c1-12)  $(stat -c%s "$src") bytes" >&2
        echo "           output/ $(md5sum "$dst" | cut -c1-12)  $(stat -c%s "$dst") bytes" >&2
        echo "         Copy it over first, or pass STALE_OK=1 if output/ is what you want." >&2
        [ "${STALE_OK:-0}" = "1" ] || die "refusing to write a stale $(basename "$dst")"
    fi
done

# BOOT.bin and the fallback ramdisk come from THE MOST RECENT CARD BACKUP by
# default, not from firmware/output - deliberately, and this is not a detail.
#
# BOOT.bin carries the bitstream, and the bitstream is a hard invariant for this
# work: every measurement in firmware-modern/baseline was taken against one
# specific build of it. firmware/output/ may well hold a DIFFERENT build - mine
# did, 65dc45f9 against the 3fb710d8 the board had been running all day - and
# quietly swapping the bitstream while also swapping the entire userspace would
# make any result that followed uninterpretable.
#
# Override with BOOT_BIN=/path/to/BOOT.bin when you actually mean to change it.
bak=$(ls -dt "$REPO"/firmware/.flash-backups/*/files 2>/dev/null | head -1 || true)
BOOTBIN="${BOOT_BIN:-}"
RAMDISK=""
if [ -z "$BOOTBIN" ]; then
    if [ -n "$bak" ] && [ -f "$bak/BOOT.bin" ]; then
        BOOTBIN="$bak/BOOT.bin"; RAMDISK="$bak/uramdisk.image.gz"
        echo "note: BOOT.bin from the latest card backup - $bak"
    elif [ -f "$REPO/firmware/output/BOOT.bin" ]; then
        BOOTBIN="$REPO/firmware/output/BOOT.bin"
        RAMDISK="$REPO/firmware/output/uramdisk.image.gz"
        echo "note: no card backup found; using firmware/output/BOOT.bin."
        echo "      CHECK THIS IS THE BITSTREAM YOU MEAN - it changes the FPGA."
    fi
fi
[ -f "$BOOTBIN" ] || die "no BOOT.bin found; set BOOT_BIN=/path/to/BOOT.bin"
[ -n "$RAMDISK" ] && [ -f "$RAMDISK" ] || RAMDISK="$REPO/firmware/output/uramdisk.image.gz"

cat <<EOF

About to COMPLETELY ERASE:

  $DEV   $(( bytes / 1024 / 1024 )) MB   $(cat "/sys/block/$name/device/model" 2>/dev/null || echo '?')
$(lsblk -no NAME,SIZE,FSTYPE,LABEL "$DEV" | sed 's/^/    /')

and write:

  p1  ${BOOT_MB} MB FAT32   $(basename "$BOOTBIN")  $(basename "$UIMG")  $(basename "$DTB")  uEnv.txt
                      $(basename "$RAMDISK")  (fallback)
  p2  the rest ext4   $(du -h "$TAR" | cut -f1) of Debian armhf

EOF
read -r -p "Type the device name again to confirm ($name): " confirm
[ "$confirm" = "$name" ] || die "not confirmed"

echo "=== unmounting anything on $DEV ==="
for p in "$DEV"?*; do umount "$p" 2>/dev/null && echo "  unmounted $p" || true; done
sync

echo "=== partitioning ==="
sfdisk --quiet --wipe always --wipe-partitions always "$DEV" <<EOF
label: dos
unit: sectors
start=2048, size=$((BOOT_MB * 2048)), type=c, bootable
start=$((2048 + BOOT_MB * 2048)), type=83
EOF
partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV"
sleep 2
P1="${DEV}1"; P2="${DEV}2"
[ -b "$P1" ] || P1="${DEV}p1"
[ -b "$P2" ] || P2="${DEV}p2"

echo "=== filesystems ==="
mkfs.vfat -F 32 -n FISHBOOT "$P1" >/dev/null
# -m 1: the default 5% reserved is 350 MB on an 8 GB card, which buys nothing
# here - this is not a filesystem that fills up with logs from many users.
mkfs.ext4 -q -L fishroot -m 1 "$P2"

mnt=$(mktemp -d)
trap 'umount -R "$mnt/p1" "$mnt/p2" 2>/dev/null || true; rmdir "$mnt/p1" "$mnt/p2" "$mnt" 2>/dev/null || true' EXIT
mkdir -p "$mnt/p1" "$mnt/p2"
mount "$P1" "$mnt/p1"
mount "$P2" "$mnt/p2"

echo "=== boot partition ==="
cp "$BOOTBIN" "$mnt/p1/BOOT.bin"
cp "$UIMG"    "$mnt/p1/uImage"
cp "$DTB"     "$mnt/p1/devicetree.dtb"
[ -f "$RAMDISK" ] && cp "$RAMDISK" "$mnt/p1/uramdisk.image.gz"
"$HERE/make-uenv.sh" > "$mnt/p1/uEnv.txt"
for f in BOOT.bin uImage devicetree.dtb uEnv.txt; do
    printf "  %-20s %s\n" "$f" "$(md5sum "$mnt/p1/$f" | cut -c1-12)"
done

echo "=== root partition ==="
tar -xf "$TAR" -C "$mnt/p2"
mkdir -p "$mnt/p2/boot" "$mnt/p2/mnt/jffs2" "$mnt/p2/proc" "$mnt/p2/sys" "$mnt/p2/dev" "$mnt/p2/run"
echo "  $(du -sh "$mnt/p2" | cut -f1) written, $(df -h "$mnt/p2" | tail -1 | awk '{print $4}') free"

sync
echo
echo "Done. The card boots the Debian root by default."
echo "To fall back to the Buildroot ramdisk, from the board or a reader:"
echo "    fw_setenv rootfs_mode ramdisk       # then reboot"
echo "and to come back:  fw_setenv rootfs_mode debian   (or unset it)"
