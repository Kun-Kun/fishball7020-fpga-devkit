#!/bin/bash
# Build the modern target's SD-card boot files, BOOT.bin included, from an XSA.
#
#     # run from: the repo root
#     ./devkit build --target modern --xsa FILE.xsa
#     ./devkit container build --target modern --xsa FILE.xsa   # no cross-compiler here?
#
#     --xsa FILE         REQUIRED. The hardware platform, with its bitstream.
#     --boot-only        BOOT.bin and uEnv.txt only; skip the kernel.   (~2 min)
#     --preflight-only   Check tools and sources, build nothing.
#
# Writes firmware-modern/output/: BOOT.bin, uImage, devicetree.dtb, uEnv.txt.
# The Debian root filesystem is built separately (firmware-modern/debian/build.sh)
# because it needs armhf emulation and takes far longer than everything here.
#
# WHAT THIS IS. The factory target's firmware/scripts/build_all.sh builds all of
# the vendor monorepo - its 5.15 kernel and its Buildroot root filesystem too.
# This builds ONLY what the modern target uses: the FSBL and U-Boot for BOOT.bin,
# from the same pinned sources (firmware/scripts/fetch_common.sh), and ADI's
# patched 6.12 kernel from firmware-modern/src/linux. The BOOT.bin it packages is
# the factory BOOT.bin rebuilt: same FSBL, same bitstream, same U-Boot source.
#
# WHY --xsa IS REQUIRED. The modern target has no Vivado path, and no default
# would be honest: at the time of writing no published release carries the
# bitstream a from-source factory build produces, so silently downloading one
# would silently build a different FPGA design. Pass the platform you mean.
set -euo pipefail

FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$FW_DIR")"
BOOT="$FW_DIR/boot"
MONO="$BOOT/fw"
KSRC="$FW_DIR/src/linux"
OUT="$FW_DIR/output"
PLUTO="$BOOT/hdl"                 # where import_xsa.sh puts the platform
FSBL_BUILD="$BOOT/fsbl-build"
BOOTGEN="$BOOT/bootgen/bootgen"
XILINX_DIR="${XILINX_DIR:-/tools/Xilinx}"
# shellcheck source=../firmware/scripts/fetch_common.sh
source "$REPO/firmware/scripts/fetch_common.sh"

usage() { sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

XSA_FILE=""; BOOT_ONLY=0; PREFLIGHT_ONLY=0; _want_xsa=0
for arg in "$@"; do
    if [ "$_want_xsa" -eq 1 ]; then XSA_FILE="$arg"; _want_xsa=0; continue; fi
    case "$arg" in
        --xsa)            _want_xsa=1 ;;
        --xsa=*)          XSA_FILE="${arg#--xsa=}" ;;
        --boot-only)      BOOT_ONLY=1 ;;
        --preflight-only) PREFLIGHT_ONLY=1 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "ERROR: unknown option '$arg' for the modern target." >&2
           echo "       (--hdl-only is the factory target's; the modern one has no HDL build.)" >&2
           exit 1 ;;
    esac
done
[ "$_want_xsa" -eq 1 ] && { echo "ERROR: --xsa needs a file path" >&2; exit 1; }
# --preflight-only (what `./devkit doctor --target modern` runs) is "can this
# machine build?", which does not depend on which XSA you will pass later.
if [ -z "$XSA_FILE" ] && [ "$PREFLIGHT_ONLY" -eq 0 ]; then
    echo "ERROR: the modern target needs --xsa FILE. It has no Vivado path." >&2
    echo "       Use your own factory build's platform:" >&2
    echo "           --xsa firmware/src/hdl/projects/pluto/system_top.xsa" >&2
    echo "       or a factory release's system_top.xsa - which is THAT release's" >&2
    echo "       design, not necessarily what your board runs." >&2
    exit 1
fi
[ -n "$XSA_FILE" ] && case "$XSA_FILE" in /*) ;; *) XSA_FILE="$PWD/$XSA_FILE" ;; esac

# ---- preflight ----------------------------------------------------------------
# Every tool and source is checked BEFORE anything is built, and a missing ARM
# Linux cross-compiler names the one command that has it, rather than failing
# ten minutes in. That compiler is what a typical desktop lacks.
fail=0
need() { if [ -e "$2" ] || command -v "$2" >/dev/null 2>&1; then printf '  ok     %s\n' "$1"
         else printf '  MISSING %s  (%s)\n' "$1" "$2"; fail=1; fi; }
echo "=== preflight ==="
[ -n "$XSA_FILE" ] && need "XSA" "$XSA_FILE"
need "kernel source"              "$KSRC/Makefile"
need "U-Boot source"              "$MONO/u-boot-xlnx/Makefile"
need "get_default_envs.sh"        "$MONO/scripts/get_default_envs.sh"
need "embeddedsw"                 "$BOOT/embeddedsw/lib"
need "bootgen source"             "$BOOT/bootgen/Makefile"
need "bare-metal cross (FSBL)"    arm-none-eabi-gcc
need "ARM Linux cross (U-Boot)"   arm-linux-gnueabi-gcc
need "mkimage (uImage)"           mkimage
need "unzip"                      unzip
if [ "$fail" -ne 0 ]; then
    echo >&2
    [ -e "$MONO/u-boot-xlnx/Makefile" ] || \
        echo "Sources missing: run  ./devkit setup --target modern" >&2
    command -v arm-linux-gnueabi-gcc >/dev/null 2>&1 || {
        echo "No ARM Linux cross-compiler on this machine. The build container has one:" >&2
        echo "    ./devkit container build --target modern --xsa ${XSA_FILE:-FILE.xsa}" >&2; }
    exit 1
fi
# The kernel builds with either ARM Linux compiler; U-Boot is pinned to the soft-
# float one, as the factory target does (firmware/scripts/build_all.sh).
if command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; then KCROSS=arm-linux-gnueabihf-
else KCROSS=arm-linux-gnueabi-; fi
UCROSS=arm-linux-gnueabi-
echo "  kernel compiler: ${KCROSS}gcc   U-Boot compiler: ${UCROSS}gcc"
[ "$PREFLIGHT_ONLY" -eq 1 ] && { echo "=== preflight passed; nothing built (--preflight-only) ==="; exit 0; }

mkdir -p "$OUT"

# ---- [1] the hardware platform --------------------------------------------------
echo "=== [1/6] Importing the XSA (shared with the factory target: import_xsa.sh) ==="
"$REPO/firmware/scripts/import_xsa.sh" "$XSA_FILE" "$PLUTO" "$OUT"
BIT="$PLUTO/pluto.runs/impl_1/system_top.bit"

# ---- [2] FSBL ------------------------------------------------------------------
echo "=== [2/6] Building the FSBL (embeddedsw) ==="
# The committed BSP headers describe ONE hardware design; refuse an XSA they do
# not match, exactly as the factory target does, rather than build an FSBL with
# the wrong peripheral addresses - a board that does not boot and prints nothing.
"$REPO/firmware/fsbl/hwcheck.py" --xsa "$PLUTO/system_top.xsa" || {
    echo "ERROR: firmware/fsbl/generated/ does not match this hardware platform." >&2
    exit 1; }
# Distro compiler, with every Xilinx directory off PATH, for the same reason the
# factory target gives: which compiler you get must not depend on whether Vitis
# happens to be installed.
FSBL_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$XILINX_DIR" | paste -sd: -)"
PATH="$FSBL_PATH" make -s -C "$REPO/firmware/fsbl" \
    ESW="$BOOT/embeddedsw" XSA="$PLUTO/system_top.xsa" BUILD="$FSBL_BUILD"
FSBL_ELF="$FSBL_BUILD/app/Debug/fsbl.elf"
[ -f "$FSBL_ELF" ] || { echo "ERROR: the FSBL build produced no fsbl.elf" >&2; exit 1; }

# ---- [3] U-Boot ----------------------------------------------------------------
echo "=== [3/6] Building U-Boot ==="
make -s -C "$MONO/u-boot-xlnx" ARCH=arm CROSS_COMPILE=$UCROSS zynq_pluto_defconfig
make -s -C "$MONO/u-boot-xlnx" ARCH=arm CROSS_COMPILE=$UCROSS UBOOTVERSION="PlutoSDR" -j"$(nproc)"
UBOOT_ELF="$MONO/u-boot-xlnx/u-boot"
[ -f "$UBOOT_ELF" ] || { echo "ERROR: the U-Boot build produced no u-boot" >&2; exit 1; }

# ---- [4] kernel ----------------------------------------------------------------
if [ "$BOOT_ONLY" -eq 1 ]; then
    echo "=== [skipped] kernel (--boot-only) - output/uImage and devicetree.dtb left as they are ==="
else
    echo "=== [4/6] Building the 6.12 kernel and the board's device tree ==="
    # fishball_defconfig, never zynq_pluto_defconfig on its own - that is an
    # ADALM-Pluto, with no Ethernet, SD card or GPIO sysfs (see README.md).
    make -s -C "$KSRC" ARCH=arm CROSS_COMPILE=$KCROSS fishball_defconfig
    make -s -C "$KSRC" ARCH=arm CROSS_COMPILE=$KCROSS uImage LOADADDR=0x8000 -j"$(nproc)"
    make -s -C "$KSRC" ARCH=arm CROSS_COMPILE=$KCROSS DTC_FLAGS=-@ xilinx/zynq-pluto-sdr-fishball.dtb
    cp "$KSRC/arch/arm/boot/uImage" "$OUT/uImage"
    # NOTE THE RENAME: the flasher wants the literal name devicetree.dtb.
    cp "$KSRC/arch/arm/boot/dts/xilinx/zynq-pluto-sdr-fishball.dtb" "$OUT/devicetree.dtb"
fi

# ---- [5] uEnv.txt ----------------------------------------------------------------
echo "=== [5/6] Generating uEnv.txt from the freshly built U-Boot ==="
# Base: U-Boot's own default environment, extracted from THIS build - never the
# factory target's output/uEnv.txt, which make-uenv.sh would otherwise fall back
# to and which need not exist, or match, on a machine that only builds modern.
UENV_WORK="$(mktemp -d)"
trap 'rm -rf "$UENV_WORK"' EXIT
( cd "$UENV_WORK" && CROSS_COMPILE=$UCROSS "$MONO/scripts/get_default_envs.sh" > base-uEnv.txt )
[ -s "$UENV_WORK/base-uEnv.txt" ] || { echo "ERROR: get_default_envs.sh produced nothing" >&2; exit 1; }
"$FW_DIR/debian/make-uenv.sh" "$UENV_WORK/base-uEnv.txt" > "$OUT/uEnv.txt"

# ---- [6] BOOT.bin ----------------------------------------------------------------
echo "=== [6/6] Packaging BOOT.bin: FSBL + bitstream + U-Boot ==="
devkit_ensure_bootgen "$BOOT/bootgen"
PKG="$(mktemp -d)"
trap 'rm -rf "$UENV_WORK" "$PKG"' EXIT
cp "$FSBL_ELF" "$PKG/fsbl.elf"
cp "$BIT" "$PKG/system_top.bit"
cp "$UBOOT_ELF" "$PKG/u-boot.elf"
cp "$REPO/firmware/scripts/boot.bif" "$PKG/boot.bif"
( cd "$PKG" && "$BOOTGEN" -image boot.bif -arch zynq -o "$OUT/BOOT.bin" -w >/dev/null )

# ---- sanity ------------------------------------------------------------------------
echo "=== Checking the output ==="
for f in BOOT.bin uEnv.txt uImage devicetree.dtb; do
    [ -s "$OUT/$f" ] || { echo "ERROR: $OUT/$f is missing or empty." >&2; exit 1; }
done
sz=$(stat -c %s "$OUT/BOOT.bin")
[ "$sz" -ge 1000000 ] || { echo "ERROR: BOOT.bin is only $sz bytes - bootgen failed quietly." >&2; exit 1; }
# Not just "a file of the right size": the three partitions BOOT.bin exists to
# carry, read back out of it, with the bitstream checked against the XSA byte for
# byte (bootgen stores it converted, so it is compared after the same conversion).
"$REPO/firmware/scripts/check_bootbin.py" "$OUT/BOOT.bin" --xsa "$PLUTO/system_top.xsa" --bootgen "$BOOTGEN"

( cd "$OUT" && sha256sum BOOT.bin uEnv.txt uImage devicetree.dtb > SHA256SUMS.boot )
echo
echo "=== Done: $OUT ==="
( cd "$OUT" && sha256sum BOOT.bin uEnv.txt uImage devicetree.dtb )
echo
echo "Onto a running board, with a backup and an md5 check before anything is swapped:"
echo "    ./devkit flash --target modern --boot-only      # BOOT.bin"
echo "    ./devkit flash --target modern --kernel-only    # uImage"
echo "Or a whole card from a reader, with the Debian root:"
echo "    ./devkit write-card --target modern /dev/sdX"
