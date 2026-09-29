#!/bin/bash
# Flash a built firmware onto the running board, over the network.
#
#     ./tools/flash.sh                 # BOOT.bin + uImage (the usual case)
#     ./tools/flash.sh --all           # all five SD-card files
#     ./tools/flash.sh --boot-only     # just the bitstream/FSBL/U-Boot
#     ./tools/flash.sh --kernel-only   # just uImage
#     ./tools/flash.sh --rootfs-only   # just uramdisk.image.gz
#     ./tools/flash.sh --no-reboot     # copy, verify, leave it running
#
# The board's FAT partition is /dev/mmcblk0p1, normally unmounted, so a running
# board can rewrite its own SD card. This is the only remote route that can
# update the FPGA bitstream - DFU has no BOOT.bin target - and it is why HDL
# iteration here does not involve a card reader.
#
# WHY THIS IS A SCRIPT AND NOT A PARAGRAPH IN THE README
# A bad BOOT.bin means a board that will not boot, and then this route is gone:
# recovery needs a card reader. Every step below exists to make that outcome
# unlikely and recoverable - back up first, verify the copy by checksum BEFORE
# swapping it in, unmount cleanly so FAT metadata is flushed, and keep the old
# one on the card. Done by hand those steps are easy to skip.
#
# Never DFU for BOOT.bin, and never pull power mid-write.
set -euo pipefail

# Where the board is: its own name first, the USB gadget last. See
# tools/board_addr.py; $BOARD still overrides everything.
BOARD="${BOARD:-$(python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board_addr.py" 2>/dev/null || echo 192.168.2.1)}"
PASS="${BOARD_PASS:-analog}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Which build to flash. Defaults to firmware/output, so every existing
# invocation is unchanged; set FW_OUTPUT to flash the other target's
# target without disturbing main's outputs or `./devkit verify --board`.
OUT="${FW_OUTPUT:-$(dirname "$SCRIPT_DIR")/firmware/output}"
BACKUP_DIR="${BACKUP_DIR:-$(dirname "$SCRIPT_DIR")/firmware/.flash-backups}"

FILES=(BOOT.bin uImage)
REBOOT=1
for arg in "$@"; do
    case "$arg" in
        --all)         FILES=(BOOT.bin devicetree.dtb uEnv.txt uImage uramdisk.image.gz) ;;
        --boot-only)   FILES=(BOOT.bin) ;;
        --kernel-only) FILES=(uImage) ;;
        # Three patches in this repo (0002, 0008, 0011) change only the device
        # tree, and a dtb change needs a reboot but not a new kernel.
        --dtb-only)    FILES=(devicetree.dtb) ;;
        --rootfs-only) FILES=(uramdisk.image.gz) ;;
        --no-reboot)   REBOOT=0 ;;
        -h|--help)     sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2
           case "$arg" in -all|-boot-only|-kernel-only|-dtb-only|-rootfs-only|-no-reboot)
               echo "did you mean -$arg? (options take two dashes)" >&2 ;; esac
           echo "options: --all  --boot-only  --kernel-only  --dtb-only  --rootfs-only  --no-reboot  --help" >&2
           exit 2 ;;
    esac
done

command -v sshpass >/dev/null || { echo "need sshpass (sudo apt install sshpass)" >&2; exit 2; }
# UserKnownHostsFile=/dev/null: every board is 192.168.2.1 and each keeps its
# own host key, so the second board you ever plug in would otherwise make
# OpenSSH refuse password auth with a "changed key" warning that sshpass hides.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10)
sh()  { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$BOARD" "$@"; }
# No scp: OpenSSH 9+ defaults scp to SFTP, and the board's dropbear has no
# sftp-server. A plain pipe over ssh works against every version.
push() { sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@$BOARD" "cat > '$2'" < "$1"; }

for f in "${FILES[@]}"; do
    [ -r "$OUT/$f" ] || { echo "missing $OUT/$f - build first" >&2; exit 1; }
done

echo "== board =="
if ! err=$(sh true 2>&1); then
    echo "cannot reach root@$BOARD: ${err:-no response}" >&2
    echo "(set BOARD=<address> and BOARD_PASS=<password> if yours differ)" >&2
    exit 1
fi
echo "   $BOARD reachable, flashing: ${FILES[*]}"
uptime_before=$(sh 'cut -d. -f1 /proc/uptime')


# MOUNTING THE CARD WHEN SOMETHING ELSE ALREADY HAS IT.
#
# This script has always mounted /dev/mmcblk0p1 at /tmp/sd, which worked because
# the Buildroot rootfs leaves the FAT partition unmounted. A Debian root does not:
# firmware-modern/debian mounts it at /boot, as any ordinary distribution would.
# `mount /dev/mmcblk0p1 /tmp/sd` then fails with
#
#     mmcblk0p1: Can't mount, would change RO state
#     mount: /tmp/sd: /dev/mmcblk0p1 already mounted on /boot.
#
# ...and flashing is impossible on the very userspace this repo now ships.
#
# So: if the partition is already mounted, BIND-mount its mountpoint into /tmp/sd.
# Every path below keeps working unchanged, and unmounting the bind afterwards
# leaves the original mount alone.
sd_mount() {   # $1 = ro | rw
    sh 'mkdir -p /tmp/sd
        existing=$(awk "\$1 == \"/dev/mmcblk0p1\" { print \$2; exit }" /proc/mounts)
        if [ -n "$existing" ] && [ "$existing" != "/tmp/sd" ]; then
            mount --bind "$existing" /tmp/sd
        elif [ "$existing" != "/tmp/sd" ]; then
            mount -o '"$1"' /dev/mmcblk0p1 /tmp/sd
        fi
        mount -o remount,'"$1"' /tmp/sd 2>/dev/null || true'
}

cleanup() { sh 'cd / && umount /tmp/sd 2>/dev/null' >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo
echo "== 1. back up what is on the card now =="
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR/$stamp"
sd_mount ro
for f in "${FILES[@]}"; do
    if sh "test -r /tmp/sd/$f"; then
        sh "cat /tmp/sd/$f" > "$BACKUP_DIR/$stamp/$f"
        on_board=$(sh "md5sum /tmp/sd/$f" | cut -d' ' -f1)
        local_md5=$(md5sum "$BACKUP_DIR/$stamp/$f" | cut -d' ' -f1)
        [ "$on_board" = "$local_md5" ] || {
            echo "   backup of $f does not match the board - refusing to continue" >&2; exit 1; }
        echo "   saved $f  ($on_board)"
    else
        echo "   $f not on the card yet - nothing to back up"
    fi
done
sh 'cd / && umount /tmp/sd'
echo "   backup: $BACKUP_DIR/$stamp"

# REFUSE TO SILENTLY UNDO A DEBIAN CARD.
#
# `--all` includes uEnv.txt, and the uEnv.txt in firmware/output/ carries only the
# ramdisk boot path. The Debian root is selected by an `sdboot_debian` block that
# lives in firmware-modern/debian/make-uenv.sh. So flashing --all onto a card
# running Debian replaces the boot selector with one that cannot reach the Debian
# root, and the next reboot comes up on Buildroot with nothing reporting an error.
# The card is intact; the board just quietly becomes a different machine.
#
# READ THE BACKUP STEP 1 JUST MADE, not the card. Two earlier versions of this
# check probed the card over ssh with a second mount and a quoted remote script,
# and both silently returned 0 for a card that demonstrably had the Debian
# selector on it - so the check sailed past and did the damage it exists to
# prevent, twice. Step 1 has already copied the card's uEnv.txt to a local file
# and md5-verified it. Grep that. No second mount, no remote quoting, no doubt.
#
# ONLY WHEN uEnv.txt IS ACTUALLY BEING WRITTEN. The condition used to be "did the
# build produce a uEnv.txt", which is true after every build - so on --boot-only,
# where FILES is just BOOT.bin, step 1 never backed a uEnv.txt up and the check
# below could only ever hit "no backup to compare against" and refuse. That made
# `./devkit flash --boot-only` impossible to run: the very command this script
# recommends three lines further down for a mixed card. Nothing is being
# downgraded when uEnv.txt is not in FILES, so there is nothing to guard.
case " ${FILES[*]} " in
    *" uEnv.txt "*) flashing_uenv=1 ;;
    *)              flashing_uenv=0 ;;
esac
if [ "$flashing_uenv" = 1 ] && [ -r "$OUT/uEnv.txt" ]; then
    card_uenv="$BACKUP_DIR/$stamp/uEnv.txt"
    if [ ! -r "$card_uenv" ]; then
        echo "   no backup of the card's uEnv.txt to compare against - refusing." >&2
        echo "   (FLASH_ALLOW_UENV_DOWNGRADE=1 overrides)" >&2
        [ "${FLASH_ALLOW_UENV_DOWNGRADE:-0}" = "1" ] || exit 1
    else
        card_n=$(grep -c sdboot_debian "$card_uenv" || true)
        new_n=$(grep -c sdboot_debian "$OUT/uEnv.txt" || true)
        echo "   uEnv.txt: the card has ${card_n:-0} sdboot_debian line(s), this build has ${new_n:-0}"
        if [ "${card_n:-0}" -gt 0 ] && [ "${new_n:-0}" -eq 0 ]; then
            cat >&2 <<'WARN'

   REFUSING. The card's uEnv.txt selects the Debian root; the one about to be
   flashed does not. This would boot the board back onto the Buildroot ramdisk,
   and nothing would report an error.

   Flash only what you rebuilt:
       ./devkit flash --boot-only                   # the bitstream
       FW_OUTPUT=$PWD/firmware-modern/output ./tools/flash.sh --kernel-only

   Or regenerate a dual-boot uEnv.txt first:
       ./firmware-modern/debian/make-uenv.sh > firmware/output/uEnv.txt

   FLASH_ALLOW_UENV_DOWNGRADE=1 if you really do mean to go back to Buildroot.
WARN
            [ "${FLASH_ALLOW_UENV_DOWNGRADE:-0}" = "1" ] || exit 1
            echo "   FLASH_ALLOW_UENV_DOWNGRADE=1 - proceeding anyway" >&2
        fi
    fi
fi

echo "== 2. copy in beside the old, and verify BEFORE swapping =="
sd_mount rw
for f in "${FILES[@]}"; do
    push "$OUT/$f" "/tmp/sd/$f.new"
    want=$(md5sum "$OUT/$f" | cut -d' ' -f1)
    got=$(sh "md5sum /tmp/sd/$f.new" | cut -d' ' -f1)
    if [ "$want" != "$got" ]; then
        echo "   $f copied WRONG ($got, wanted $want) - removing every .new, card untouched" >&2
        sh "rm -f /tmp/sd/*.new; cd / && umount /tmp/sd"
        exit 1
    fi
    echo "   $f verified  ($want)"
done

echo
echo "== 3. swap, flush, unmount =="
for f in "${FILES[@]}"; do
    # Keep the previous copy ON the card. If that copy cannot be made (card
    # full), stop before the swap rather than swap with no on-card fallback.
    if ! sh "cd /tmp/sd && { [ ! -r $f ] || cp $f $f.prev; } && mv $f.new $f"; then
        echo "   could not keep $f.prev (card full?) - $f NOT swapped; card unchanged" >&2
        sh "rm -f /tmp/sd/*.new; sync; cd / && umount /tmp/sd"
        exit 1
    fi
done
sh 'sync; cd / && umount /tmp/sd'
echo "   done - previous copies kept on the card as *.prev"

if [ "$REBOOT" -eq 0 ]; then
    echo
    echo "Not rebooting (--no-reboot). The board is still running the OLD firmware"
    echo "until it restarts."
    exit 0
fi

echo
echo "== 4. reboot =="
sh '(sleep 1; reboot) >/dev/null 2>&1 &' || true
# "It answered ssh" is not "it rebooted": a board tearing down its services can
# still answer for a few seconds, and that used to print "back after 7s" with
# the OLD firmware still running. Require the uptime counter to have reset.
for i in $(seq 1 90); do
    sleep 2
    if up=$(sh 'cut -d. -f1 /proc/uptime' 2>/dev/null) && [ -n "$up" ]; then
        if [ "$up" -lt "${uptime_before:-999999}" ] && [ "$up" -lt 300 ]; then
            echo "   back after $((i * 2))s (uptime reset: ${up}s)"
            echo
            echo "== 5. confirm the card holds what we sent =="
            # /tmp is tmpfs - the reboot just erased the mount point.
            sd_mount ro
            bad=0
            for f in "${FILES[@]}"; do
                want=$(md5sum "$OUT/$f" | cut -d' ' -f1)
                got=$(sh "md5sum /tmp/sd/$f" | cut -d' ' -f1)
                if [ "$want" = "$got" ]; then echo "   $f  ok"; else echo "   $f  MISMATCH ($got)"; bad=1; fi
            done
            sh 'cd / && umount /tmp/sd'
            sh 'cat /opt/VERSIONS 2>/dev/null | head -1' || true
            echo
            if [ $bad -eq 0 ]; then
                echo "Flashed and booted. Previous firmware is on the card as *.prev"
                echo "and in $BACKUP_DIR/$stamp."
                exit 0
            fi
            echo "Booted, but the card does not hold what was sent - investigate before trusting it." >&2
            exit 1
        fi
        fi                          # else: still the old instance answering; keep waiting
done

echo "   board has not come back after ~3 minutes." >&2
echo "   It may still be booting. If it does not return, the previous firmware is" >&2
echo "   in $BACKUP_DIR/$stamp - restore it with a card reader." >&2
exit 1
