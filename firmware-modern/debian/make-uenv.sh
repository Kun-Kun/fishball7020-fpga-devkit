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
sdboot_debian=echo Booting the Debian root on mmcblk0p2... && setenv bootargs console=ttyPS0,115200n8 maxcpus=${maxcpus} root=/dev/mmcblk0p2 rootwait rw clk_ignore_unused && load mmc 0 ${fit_load_address} ${kernel_image} && load mmc 0 ${devicetree_load_address} ${devicetree_image} && bootm ${fit_load_address} - ${devicetree_load_address}
sdboot=if mmcinfo; then run uenvboot; if test "${rootfs_mode}" = "ramdisk"; then run sdboot_ramdisk; else run sdboot_debian; fi; fi
EOF
