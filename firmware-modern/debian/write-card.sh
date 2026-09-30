#!/bin/bash
# Put the Debian root and the boot files onto an SD card.
#
#     # run from: the repo root
#     sudo ./devkit write-card --target modern /dev/sdX
#     ./devkit write-card --target modern --dry-run /dev/sdX   # show the plan, write nothing
#     sudo ./devkit write-card --target modern --image card.img # a NEW image file, not a disk
#
# --image FILE writes the same layout into a new file through a loop device, so
# the whole path - partitioning, both filesystems, every copy - can be exercised
# without a card. It does NOT relax any check on a real device: those checks stay
# exactly as they are, and apply to anything that is not a file this run created.
#
# THIS DESTROYS EVERYTHING ON THE TARGET. It refuses any device that is not
# removable and anything that is a partition rather than a whole disk, unmounts
# the target's own partitions (as listed by lsblk), and prints what it is about to
# do first - then makes you type the device name. The one mistake this class of script
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
# Partition N of a whole-disk device, by the kernel's own naming rule: a name that
# ends in a digit gets a "p" (mmcblk0 -> mmcblk0p1, loop1 -> loop1p1), anything
# else does not (sdb -> sdb1). The old test - "${DEV}1, and if that is not a
# block device try ${DEV}p1" - took /dev/loop11 for partition 1 of /dev/loop1
# whenever loop11 existed, which it does on any machine with a dozen loop devices,
# and mkfs then ran on somebody else's loop device. Never guess by probing.
part() { case "$1" in *[0-9]) echo "${1}p$2" ;; *) echo "${1}$2" ;; esac; }


DRY=0; IMAGE=""; IMAGE_MB=2048; DEV=""
_usage="usage: sudo $0 [--dry-run] /dev/sdX  |  sudo $0 [--dry-run] --image NEW_FILE [--size MB]"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --image)   shift; IMAGE="${1:-}"; [ -n "$IMAGE" ] || die "--image needs a file name" ;;
        --size)    shift; IMAGE_MB="${1:-}"; case "$IMAGE_MB" in ''|*[!0-9]*) die "--size needs megabytes" ;; esac ;;
        -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        die "unknown option $1"$'\n'"$_usage" ;;
        *)         [ -z "$DEV" ] || die "$_usage"; DEV="$1" ;;
    esac
    shift
done
if [ -n "$IMAGE" ]; then
    [ -z "$DEV" ] || die "give a device OR --image, not both"
    # A NEW file only. Refusing an existing one keeps --image from becoming a
    # quieter way to overwrite something, and makes the mode safe to run unattended.
    [ ! -e "$IMAGE" ] || die "$IMAGE already exists - --image writes a NEW file, it never overwrites"
    [ "$IMAGE_MB" -ge 1024 ] || die "--size $IMAGE_MB is too small; a Debian root needs ~1 GB minimum"
else
    [ -n "$DEV" ] || die "$_usage"
    [ "$IMAGE_MB" = 2048 ] || die "--size only means something with --image"
fi
[ "$DRY" -eq 1 ] || [ "$(id -u)" = 0 ] || die "needs root (it partitions a disk); --dry-run does not"
[ -f "$TAR" ] || die "$TAR not found - run ./build.sh first"

# rootfs.tar is a BUILD ARTEFACT; overlay/ is the source of truth. Nothing
# rebuilds the tar when the overlay changes, and write-card.sh only extracts the
# tar - so an overlay fix lands in git and never reaches the card, silently.
#
# That happened: the production card written on 2026-09-28 got a rootfs built on
# the 27th, missing the systemd-logind mask and system.conf.d/fishball.conf -
# the fixes for the 29-minute shutdown. It booted in 75 s instead of 14 s and
# would have reintroduced the hang. Nothing warned.
newer=$(find "$HERE/overlay" -newer "$TAR" \( -type f -o -type l \) -print -quit 2>/dev/null || true)
if [ -n "$newer" ]; then
    echo "WARNING: overlay/ has files newer than $(basename "$TAR"):" >&2
    find "$HERE/overlay" -newer "$TAR" \( -type f -o -type l \) -printf '           %P\n' 2>/dev/null | head -10 >&2
    echo "         The card would get a rootfs WITHOUT them. Rebuild with ./build.sh," >&2
    echo "         or pass OVERLAY_OK=1 if the tar really is what you want." >&2
    [ "${OVERLAY_OK:-0}" = "1" ] || die "refusing to write a rootfs older than the overlay"
fi

if [ -n "$IMAGE" ]; then
    # Size only, for now. The file and its loop device are made just before
    # partitioning, once every other check has passed - making them here left a
    # half-made image behind on any later failure, which the next run then
    # refused as "already exists".
    name="$(basename "$IMAGE")"; bytes=$(( IMAGE_MB * 1024 * 1024 ))
else
    [ -b "$DEV" ] || die "$DEV is not a block device"
    name=$(basename "$DEV")
    [ -e "/sys/block/$name" ] || die "$DEV is a partition, not a disk - pass the whole device"
    [ "$(cat "/sys/block/$name/removable")" = "1" ] \
        || die "$DEV is NOT removable. Refusing. This is the check that stops this script eating a system disk."
    bytes=$(( $(cat "/sys/block/$name/size") * 512 ))
fi
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

# WHICH BOOT.bin. In order: BOOT_BIN=/path if you set it; the modern build's own
# output/BOOT.bin if it made one; else the newest card backup that contains one;
# else the factory target's output. BOOT.bin carries the FPGA bitstream, so the
# choice is printed, and compared with the card being overwritten when that can be
# read - an FPGA change is never silent.
#
# Override with BOOT_BIN=/path/to/BOOT.bin when you actually mean to change it.
# Find the newest backup that ACTUALLY CONTAINS a BOOT.bin, across both layouts
# this repo produces. Two traps, both of which made an earlier version of this
# silently fall through to firmware/output/ - the case the comment above calls
# dangerous:
#
#   * tools/flash.sh writes its backups FLAT (.flash-backups/<stamp>/BOOT.bin),
#     not under a files/ subdirectory. A glob for */files matches nothing.
#   * and it backs up only the files it flashed, so a `--kernel-only` backup
#     contains uImage and devicetree.dtb and NO BOOT.bin.
#
# So test for the file, not for the directory.
BOOTBIN="${BOOT_BIN:-}"
RAMDISK=""
# The modern target now builds its OWN BOOT.bin (./devkit build --target modern),
# from an XSA you named, checked partition by partition against it and recorded
# in output/xsa-provenance.txt. That removes the reason this used to avoid an
# output/ BOOT.bin - an output directory holding a bitstream nobody chose - so it
# is the default when it exists. The bitstream is still printed below, and still
# compared with the last card backup's, so a design change is never silent.
if [ -z "$BOOTBIN" ] && [ -f "$FW/output/BOOT.bin" ]; then
    BOOTBIN="$FW/output/BOOT.bin"
    echo "note: BOOT.bin from the modern build - $BOOTBIN"
    [ -r "$FW/output/xsa-provenance.txt" ] && \
        sed -n 's/^\(source\|bitstream_md5\):/      \1:/p' "$FW/output/xsa-provenance.txt"
fi
if [ -z "$BOOTBIN" ]; then
    bak=""
    for d in $(ls -dt "$REPO"/firmware/.flash-backups/*/files \
                      "$REPO"/firmware/.flash-backups/*/ 2>/dev/null); do
        [ -f "$d/BOOT.bin" ] && bak="${d%/}" && break
    done
    if [ -n "$bak" ]; then
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
# A changed FPGA design must never be silent. Compare the bitstream with THE CARD
# BEING OVERWRITTEN, which is the only honest reference: it is what the board was
# running. A flash backup is not - it records what a card held BEFORE that flash,
# so "the newest backup" is the state before last time. Comparing against it
# first reported a DIFFERENT bitstream for a BOOT.bin byte-identical to the one
# the board was running.
_ref=""
if [ -z "$IMAGE" ] && [ "$(id -u)" = 0 ]; then
    _p1="$(part "$DEV" 1)"
    if [ -b "$_p1" ]; then
        _roMNT="$(mktemp -d)"; _refcopy="$(mktemp)"
        # -t vfat: the card's p1 is FAT, and naming the type means an ext4 p1 is
        # simply not mounted, rather than mounted "read-only" - which still
        # replays its journal onto the card, before the confirmation prompt.
        if mount -o ro -t vfat "$_p1" "$_roMNT" 2>/dev/null; then
            [ -f "$_roMNT/BOOT.bin" ] && cp "$_roMNT/BOOT.bin" "$_refcopy" && _ref="$_refcopy"
            umount "$_roMNT" 2>/dev/null || true
        fi
        rmdir "$_roMNT" 2>/dev/null || true
    fi
fi
if [ -n "$_ref" ]; then
    # --require-same makes the exit code the answer, so "could not compare" (a
    # missing bootgen, an unreadable image) is not reported as "different".
    "$REPO/firmware/scripts/check_bootbin.py" "$BOOTBIN" --ref "$_ref" --require-same system_top.bit >/dev/null 2>&1
    case $? in
        0) echo "note: same FPGA bitstream as the card you are about to overwrite" ;;
        3) echo "WARNING: this BOOT.bin carries a DIFFERENT FPGA bitstream from the card" >&2
           echo "         you are about to overwrite. If that is not what you meant, stop now." >&2 ;;
        *) echo "note: could not compare bitstreams with the card being overwritten" >&2 ;;
    esac
    rm -f "$_ref"
else
    # No card to compare against: a --dry-run without root, an --image, or a card
    # with no BOOT.bin. There is no honest substitute - a flash backup records the
    # card BEFORE its last flash - so say what is being written instead.
    echo "note: nothing to compare the FPGA bitstream with; writing the one below"
fi
[ -r "$FW/output/xsa-provenance.txt" ] && [ "$BOOTBIN" = "$FW/output/BOOT.bin" ] && \
    sed -n 's/^\(source\|bitstream_md5\):/      \1:/p' "$FW/output/xsa-provenance.txt"
[ -n "$RAMDISK" ] && [ -f "$RAMDISK" ] || RAMDISK="$REPO/firmware/output/uramdisk.image.gz"

cat <<EOF

About to COMPLETELY ERASE:

  ${IMAGE:-$DEV}   $(( bytes / 1024 / 1024 )) MB   $( [ -n "$IMAGE" ] && echo "(a new image file)" || cat "/sys/block/$name/device/model" 2>/dev/null || echo '?')
$( [ -n "$DEV" ] && lsblk -no NAME,SIZE,FSTYPE,LABEL "$DEV" 2>/dev/null | sed 's/^/    /')

and write:

  p1  ${BOOT_MB} MB FAT32   $(basename "$BOOTBIN")  $(basename "$UIMG")  $(basename "$DTB")  uEnv.txt
                      $( [ -f "$RAMDISK" ] && echo "$(basename "$RAMDISK")  (the Buildroot fallback)" || echo "(no Buildroot ramdisk here - so no fallback root on this card)")
  p2  the rest ext4   $(du -h "$TAR" | cut -f1) of Debian armhf

EOF
if [ "$DRY" -eq 1 ]; then
    echo "--dry-run: every check passed and nothing was written."
    exit 0
fi
if [ -z "$IMAGE" ]; then
    read -r -p "Type the device name again to confirm ($name): " confirm
    [ "$confirm" = "$name" ] || die "not confirmed"
fi

if [ -n "$IMAGE" ]; then
    # Created HERE, over a file created HERE, so this loop device cannot be a
    # system disk - the one thing the removable check exists to catch. Detached
    # on exit whatever happens.
    truncate -s "${IMAGE_MB}M" "$IMAGE"
    DEV="$(losetup -fP --show "$IMAGE")"
    trap 'losetup -d "$DEV" 2>/dev/null || true' EXIT
    echo "note: --image $IMAGE on $DEV"
fi

echo "=== unmounting anything on $DEV ==="
# The partitions lsblk says belong to THIS disk. The glob "$DEV"?* this replaced
# also matched /dev/loop10 .. /dev/loop19 for /dev/loop1, and unmounted them.
for p in $(lsblk -lnpo NAME "$DEV" 2>/dev/null | tail -n +2); do
    umount "$p" 2>/dev/null && echo "  unmounted $p" || true
done
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
P1="$(part "$DEV" 1)"; P2="$(part "$DEV" 2)"
[ -b "$P1" ] && [ -b "$P2" ] || die "partitions $P1 / $P2 did not appear after partitioning $DEV"

echo "=== filesystems ==="
mkfs.vfat -F 32 -n FISHBOOT "$P1" >/dev/null
# -m 1: the default 5% reserved is 350 MB on an 8 GB card, which buys nothing
# here - this is not a filesystem that fills up with logs from many users.
mkfs.ext4 -q -L fishroot -m 1 "$P2"

mnt=$(mktemp -d)
# ONE handler: `trap` replaces, and --image already installed one to detach the
# loop device. Replacing it would leak the loop device on every image run.
trap 'umount -R "$mnt/p1" "$mnt/p2" 2>/dev/null || true; rmdir "$mnt/p1" "$mnt/p2" "$mnt" 2>/dev/null || true; [ -n "$IMAGE" ] && losetup -d "$DEV" 2>/dev/null || true' EXIT
mkdir -p "$mnt/p1" "$mnt/p2"
mount "$P1" "$mnt/p1"
mount "$P2" "$mnt/p2"

echo "=== boot partition ==="
cp "$BOOTBIN" "$mnt/p1/BOOT.bin"
cp "$UIMG"    "$mnt/p1/uImage"
cp "$DTB"     "$mnt/p1/devicetree.dtb"
[ -f "$RAMDISK" ] && cp "$RAMDISK" "$mnt/p1/uramdisk.image.gz"
# The modern build writes its own uEnv.txt, from its own U-Boot's default
# environment. Calling make-uenv.sh with no argument used to fall back to the
# FACTORY target's firmware/output/uEnv.txt, which a modern-only machine need not
# have, or have in the matching version.
if [ -s "$FW/output/uEnv.txt" ]; then cp "$FW/output/uEnv.txt" "$mnt/p1/uEnv.txt"
else "$HERE/make-uenv.sh" > "$mnt/p1/uEnv.txt"; fi
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
if [ -f "$mnt/p1/uramdisk.image.gz" ]; then
    echo "To fall back to the Buildroot ramdisk, from the board or a reader:"
    echo "    fw_setenv rootfs_mode ramdisk       # then reboot"
    echo "and to come back:  fw_setenv rootfs_mode debian   (or unset it)"
else
    echo "This card has NO Buildroot ramdisk, so rootfs_mode=ramdisk would not boot."
fi
