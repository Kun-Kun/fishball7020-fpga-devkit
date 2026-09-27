#!/bin/bash
# Emit a uEnv.txt that can boot EITHER the Debian root on p2 or the Buildroot
# ramdisk, selected by a single U-Boot variable.
#
#     ./make-uenv.sh [base-uEnv.txt] > uEnv.txt
#
# HOW THE SELECTION WORKS, and why it is done this way.
#
# U-Boot's `preboot` imports this file into its environment on every SD boot, so
# anything defined here OVERRIDES what `fw_setenv` saved to QSPI. That is exactly
# why `rootfs_mode` is *not* defined here - only tested. Define it and
# `fw_setenv rootfs_mode ramdisk` would appear to work and then be silently
# overridden on the next boot, which is the worst kind of switch.
#
#     fw_setenv rootfs_mode ramdisk     # boot Buildroot next time
#     fw_setenv rootfs_mode debian      # or unset it - Debian is the default
#
# `net.ifnames=0` IS LOAD-BEARING, and its absence cost the first boot.
#
# The kernel names the Cadence GEM `eth0`; systemd-udevd then renames it using
# predictable-interface-name rules:
#
#     macb e000b000.ethernet eth0: Cadence GEM rev 0x00020118 ...
#     macb e000b000.ethernet end0: renamed from eth0
#     ifup: failed to bring up eth0
#
# So /etc/network/interfaces asked for eth0, the device was end0, networking.service
# failed, and the board came up with no network at all - on a card that had just
# replaced its only other route in.
#
# Turning predictable names OFF rather than renaming to end0 is deliberate: this
# board has exactly one Ethernet interface and always will, and everything else -
# docs/networking.md, `./devkit net`, firmware/patches/0013, the Buildroot rootfs
# it replaces - says eth0. Predictable names solve a problem this board does not
# have, at the cost of a contract it does.
#
# TWO THINGS IN `sdboot` ARE DEFENSIVE, and the first version had neither.
#
# `test "x${rootfs_mode}" = "xramdisk"` rather than `test "${rootfs_mode}" = ...`
# because U-Boot's hush does not reliably preserve an empty quoted string as an
# argument. With the variable unset the comparison can collapse to `test = ramdisk`,
# which is a usage error rather than false - and a failing `test` inside `if` can
# take the whole `sdboot` down, leaving U-Boot at its prompt with no network and
# nothing to say why. The `x` prefix means the argument is never empty. Every
# board's stock environment uses this idiom; ADI's own uEnv.txt mostly does not,
# which is what made it look safe.
#
# `run sdboot_debian || run sdboot_ramdisk` because `bootm` does not return on
# success, so the `||` fires only when the Debian path genuinely failed to load a
# kernel or device tree. It does NOT catch a root filesystem that fails to mount -
# that happens long after U-Boot has handed over - but it does catch a missing or
# corrupt uImage, which is the failure a card write can actually cause.
#
# The ramdisk path deliberately does NOT set bootargs. This board's `bootargs` is
# not in the U-Boot environment at all (checked: `fw_printenv bootargs` is unset,
# and /proc/cmdline reads "root=/dev/ram rw earlyprintk"), so it comes from
# U-Boot's own built-in default. Leaving it alone keeps the fallback bit-for-bit
# the boot that works today, which is the entire value of having a fallback.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$(dirname "$HERE")")"

BASE="${1:-}"
if [ -z "$BASE" ]; then
    for c in "$REPO/firmware/output/uEnv.txt" \
             "$(ls -dt "$REPO"/firmware/.flash-backups/*/files/uEnv.txt 2>/dev/null | head -1)" \
             "$(ls -dt "$REPO"/firmware/.flash-backups/*/uEnv.txt 2>/dev/null | head -1)"; do
        [ -n "$c" ] && [ -f "$c" ] && BASE="$c" && break
    done
fi
[ -n "$BASE" ] && [ -f "$BASE" ] || { echo "no base uEnv.txt found; pass one" >&2; exit 1; }
grep -q '^sdboot=' "$BASE" || { echo "$BASE has no sdboot= line" >&2; exit 1; }

# Everything except the old sdboot line, unchanged.
grep -v '^sdboot=' "$BASE"

cat <<'EOF'
sdboot_ramdisk=echo Booting the Buildroot ramdisk... && load mmc 0 ${fit_load_address} ${kernel_image} && load mmc 0 ${devicetree_load_address} ${devicetree_image} && load mmc 0 ${ramdisk_load_address} ${ramdisk_image} && bootm ${fit_load_address} ${ramdisk_load_address} ${devicetree_load_address}
sdboot_debian=echo Booting the Debian root on mmcblk0p2... && setenv bootargs console=ttyPS0,115200n8 maxcpus=${maxcpus} root=/dev/mmcblk0p2 rootwait rw clk_ignore_unused net.ifnames=0 && load mmc 0 ${fit_load_address} ${kernel_image} && load mmc 0 ${devicetree_load_address} ${devicetree_image} && bootm ${fit_load_address} - ${devicetree_load_address}
sdboot=if mmcinfo; then run uenvboot; if test "x${rootfs_mode}" = "xramdisk"; then run sdboot_ramdisk; else run sdboot_debian || run sdboot_ramdisk; fi; fi
EOF
