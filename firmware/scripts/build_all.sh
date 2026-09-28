#!/bin/bash
# Full build: HDL -> bitstream -> FSBL -> u-boot -> kernel -> rootfs -> SD-card
# file set (BOOT.bin, devicetree.dtb, uEnv.txt, uImage, uramdisk.image.gz).
#
# Run ./setup.sh once first to clone the upstream source and apply patches/.
# Output lands in ../output/.
#
# This build reproduces the board's actual factory-default firmware (USB +
# Ethernet). Verified this session: devicetree.dtb comes out byte-for-byte
# identical to the real working firmware; uEnv.txt and the rootfs file list
# are content-identical (uEnv.txt differs only in U-Boot's internal env
# hash-table dump order, which doesn't affect boot behavior); the kernel's
# uImage and BOOT.bin are extremely close but not byte-identical, because the
# upstream repo's git history has been squashed to a single commit dated
# after this board's firmware was actually built, so a handful of source
# lines have drifted since (not recoverable from the public repo alone).

set -euo pipefail
BUILD_ALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW1_DIR="$(dirname "$BUILD_ALL_DIR")"
REPO_ROOT="$(dirname "$FW1_DIR")"
SRC_DIR="$FW1_DIR/src"
OUT_DIR="$FW1_DIR/output"

if [ ! -d "$SRC_DIR" ]; then
    echo "ERROR: $SRC_DIR not found. Run ./setup.sh first." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
# Stages 3-5 (u-boot, kernel, root filesystem) produce byte-identical output
# when only the HDL has changed, and together they are most of the wall time.
# --hdl-only reuses what is already in src/ and rebuilds just the parts that
# actually depend on the bitstream: HDL -> FSBL -> uEnv.txt -> BOOT.bin.
HDL_ONLY=0
PREFLIGHT_ONLY=0
# --xsa takes a hardware platform somebody else (or an earlier build) already
# produced, and skips stage [1/7] entirely. See docs/building-without-vivado.md.
XSA_FILE=""
_want_xsa=0
for arg in "$@"; do
    if [ "$_want_xsa" -eq 1 ]; then XSA_FILE="$arg"; _want_xsa=0; continue; fi
    case "$arg" in
        --hdl-only) HDL_ONLY=1 ;;
        --preflight-only) PREFLIGHT_ONLY=1 ;;
        --xsa) _want_xsa=1 ;;
        --fsbl=*)
            echo "ERROR: --fsbl was removed on 2026-09-28. The FSBL is built from" >&2
            echo "       AMD's embeddedsw and needs no Xilinx tool." >&2
            echo "       To check it still matches what Vitis produces:" >&2
            echo "         make -C firmware/fsbl CROSS=\$VITIS_CROSS compare" >&2
            exit 2 ;;
        --xsa=*) XSA_FILE="${arg#--xsa=}" ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--hdl-only] [--preflight-only] [--xsa FILE]"
            echo "  --hdl-only        rebuild HDL, FSBL and packaging only, reusing the"
            echo "                    existing kernel, u-boot and root filesystem."
            echo "  --preflight-only  run the checks that guard the build, then stop."
            echo "  --xsa FILE        use an already-built hardware platform and do NOT"
            echo "                    run Vivado. No Vitis needed either: the FSBL is"
            echo "                    built from embeddedsw plus the ps7_init.c in the .xsa."
            echo "                    See docs/building-without-vivado.md"
            exit 0 ;;
        *) echo "ERROR: unknown option '$arg' (try --help)" >&2; exit 1 ;;
    esac
done

[ "$_want_xsa" -eq 1 ] && { echo "ERROR: --xsa needs a file path" >&2; exit 1; }
if [ -n "$XSA_FILE" ]; then
    case "$XSA_FILE" in /*) ;; *) XSA_FILE="$PWD/$XSA_FILE" ;; esac
    echo "*** --xsa: importing $XSA_FILE, Vivado will NOT run ***"
fi
[ "$HDL_ONLY" -eq 1 ] && echo "*** --hdl-only: skipping u-boot, kernel and rootfs stages ***"

# ---------------------------------------------------------------------------
# Preflight. This build takes the better part of an hour and the stages that
# need a given tool are spread across all of it - the FSBL stage, for example,
# is ~40 minutes in. Discovering a missing package there is miserable, so
# check everything up front and fail in two seconds instead.
# ---------------------------------------------------------------------------
preflight_fail=0
for c in git make dtc mkimage bison flex python3; do
    command -v "$c" >/dev/null 2>&1 || {
        echo "ERROR: '$c' not found." >&2; preflight_fail=1; }
done
XILINX_DIR="${XILINX_DIR:-/tools/Xilinx}"
# The FSBL is compiled from embeddedsw with a plain cross-compiler; the
# ps7_init.c it needs comes out of
# inside the hardware platform, so there is no build without it. Vivado is
# only required when we are actually going to run it, which --xsa skips; that
# is the whole point of the flag, and demanding the tool anyway would defeat it.
# bootgen packages BOOT.bin and is still needed. It is hardlinked into both
# Vivado and Vitis, so accept either - requiring the Vitis copy specifically
# would break the moment Vitis is uninstalled, which is now a supported state.
_required_tools=""
if [ -x "$XILINX_DIR/Vivado/2022.2/bin/bootgen" ]; then :
elif [ -x "$XILINX_DIR/Vitis/2022.2/bin/bootgen" ]; then :
else
    echo "ERROR: bootgen not found under Vivado or Vitis - packaging will fail" >&2
    preflight_fail=1
fi
command -v "${CROSS_FSBL:-arm-none-eabi-}gcc" >/dev/null 2>&1 || {
    echo "ERROR: ${CROSS_FSBL:-arm-none-eabi-}gcc not found - the FSBL needs it." >&2
    echo "       sudo apt install gcc-arm-none-eabi libnewlib-arm-none-eabi" >&2
    preflight_fail=1; }
[ -d "$SRC_DIR/embeddedsw" ] || {
    echo "ERROR: $SRC_DIR/embeddedsw is missing - the FSBL is built from it." >&2
    echo "       ./devkit setup" >&2
    preflight_fail=1; }
[ -z "$XSA_FILE" ] && _required_tools="$XILINX_DIR/Vivado/2022.2/bin/vivado $_required_tools"
for f in $_required_tools; do
    [ -x "$f" ] || { echo "ERROR: missing $f (is that tool installed under $XILINX_DIR?)" >&2
                     preflight_fail=1; }
done
# The kernel builds GCC plugins (scripts/gcc-plugins), which include gmp.h
# from the compiler's plugin headers. Ask the compiler rather than guessing a
# path - it lives at /usr/include/gmp.h on some distros and under a multiarch
# directory on others. Without it the build dies ~50 minutes in, at stage 4.
if ! echo '#include <gmp.h>' | gcc -E -x c - >/dev/null 2>&1; then
    echo "ERROR: gmp.h not found - the kernel's GCC plugins cannot build." >&2
    echo "       sudo apt install -y libgmp-dev libmpc-dev libmpfr-dev" >&2
    preflight_fail=1
fi

# --hdl-only reuses u-boot/kernel/rootfs from a previous FULL build. Check for
# them here, not 25 minutes in after synthesis and the FSBL have already run.
if [ "$HDL_ONLY" -eq 1 ]; then
    for f in "$SRC_DIR/u-boot-xlnx/u-boot" "$SRC_DIR/linux/arch/arm/boot/uImage" \
             "$SRC_DIR/buildroot/output/images/rootfs.cpio.gz"; do
        [ -f "$f" ] || { echo "ERROR: --hdl-only needs a previous full build; $f is missing." >&2
                         echo "       Run a plain ./devkit build once first." >&2
                         preflight_fail=1; }
    done
fi

# Building an unpatched tree gives 70 minutes of the wrong firmware. setup.sh
# stamps src/ with a digest of the patch set it applied; a missing or stale
# stamp means either setup never finished or a git pull brought new patches.
STAMP="$SRC_DIR/.devkit-patches-applied"
if [ ! -f "$STAMP" ]; then
    echo "ERROR: $SRC_DIR carries no patch stamp - setup.sh has not completed on it." >&2
    echo "       Run ./devkit setup (safe to re-run), then build." >&2
    preflight_fail=1
else
    # The stamp lists one "sha256  name" line per applied patch. Anything in
    # patches/ that is not in it has not been applied - a git pull bringing a
    # new patch is the common case - and building without it produces firmware
    # that silently lacks the change.
    for p in "$FW1_DIR"/patches/*.patch; do
        line="$(sha256sum "$p" | cut -d' ' -f1)  $(basename "$p")"
        grep -qxF "$line" "$STAMP" || {
            echo "ERROR: $(basename "$p") is not applied (or has changed since it was)." >&2
            echo "       Run ./devkit setup, then build." >&2
            preflight_fail=1; }
    done
fi

# A Vivado project that already exists is REUSED by build_hdl.tcl: it re-runs
# synthesis but never re-sources system_bd.tcl, so an edited block design,
# top level, constraint file or coefficient set is silently ignored and the
# old bitstream is rebuilt. Catch that by mtime rather than let it happen.
PLUTO="$SRC_DIR/hdl/projects/pluto"
# Irrelevant under --xsa: the guard exists because build_hdl.tcl reuses an
# existing project and would ignore an edited system_bd.tcl. With Vivado not
# running at all there is no project to reuse, and refusing here would block a
# perfectly good build for a reason that cannot apply.
if [ -z "$XSA_FILE" ] && [ -f "$PLUTO/pluto.xpr" ]; then
    stale=""
    for f in "$PLUTO"/system_bd.tcl "$PLUTO"/system_top.v "$PLUTO"/system_constr.xdc \
             "$PLUTO"/*.v "$BUILD_ALL_DIR"/coefile_*.coe; do
        [ -f "$f" ] && [ "$f" -nt "$PLUTO/pluto.xpr" ] && stale="$stale $(basename "$f")"
    done
    if [ -n "$stale" ] && [ -z "${FORCE_STALE_PROJECT:-}" ]; then
        echo "ERROR: these design sources are newer than the existing Vivado project:$stale" >&2
        echo "       build_hdl.tcl would reuse the OLD block design and ignore them." >&2
        echo "       Delete the project so it is regenerated from the sources:" >&2
        echo "           rm -rf $PLUTO/pluto.{xpr,cache,gen,hw,ip_user_files,runs,sim,srcs,sdk}" >&2
        echo "       (or set FORCE_STALE_PROJECT=1 if you really mean to keep it)" >&2
        preflight_fail=1
    fi
fi
[ "$preflight_fail" -eq 0 ] || { echo "Preflight failed - fix the above and re-run." >&2; exit 1; }
[ "$PREFLIGHT_ONLY" -eq 1 ] && { echo "Preflight passed."; exit 0; }

export CROSS_COMPILE=arm-linux-gnueabihf-

# IMPORTANT: Vivado's own settings64.sh (sourced by tools/env-vivado.sh)
# does much more than add Vivado's own bin/ to PATH - it also prepends a
# long list of Xilinx-bundled cross-toolchain directories for every
# architecture Vivado/Vitis knows about (microblaze, arm, aarch32, aarch64,
# armr5, ...). Left in PATH for the rest of the script, this actively
# breaks the kernel build: its gcc-plugin infrastructure ends up loading
# ./scripts/gcc-plugins/arm_ssp_per_task_plugin.so against a mismatched
# libc.so.6 living under one of those Xilinx toolchain directories, failing
# with "GLIBC_2.38 not found" (confirmed by reproducing it with a clean
# kernel tree and manually inspecting PATH/LD_LIBRARY_PATH during
# development - this is Vivado's own settings script doing this, not
# anything this repo's scripts add).
#
# Fix: capture a clean PATH *before* sourcing env-vivado.sh, and use only
# that clean PATH (plus this project's own toolchain dirs) for the u-boot/
# kernel/buildroot steps below, which need none of Vivado's own tools.
# Vivado/Vitis/bootgen are re-added, narrowly, only around the steps that
# actually need them.
CLEAN_PATH="$PATH"
TOOLCHAIN_PATH="$SRC_DIR/buildroot/output/host/bin:$SRC_DIR/buildroot/output/host/sbin:$CLEAN_PATH"

# Apply the board defconfig, then force every source download to go to
# Buildroot's own mirror FIRST.
#
# By default Buildroot tries each package's upstream URL before falling back
# to BR2_BACKUP_SITE. For the many GNU packages (m4, autoconf, automake,
# libtool, ...) that upstream URL is http://ftpmirror.gnu.org, a redirector
# that is regularly slow or unroutable - and every unreachable mirror costs a
# multi-minute TCP timeout before the fallback is even attempted, which can
# stall or fail the build for reasons that have nothing to do with this repo.
# sources.buildroot.net carries the same tarballs and is reliable.
#
# This changes only WHERE sources are fetched from, never WHAT is fetched:
# Buildroot still verifies every download against the recorded .hash file.
buildroot_defconfig() {
    PATH="$CLEAN_PATH" make -C "$SRC_DIR/buildroot" ARCH=arm zynq_pluto_defconfig
    sed -i '/^BR2_PRIMARY_SITE=/d' "$SRC_DIR/buildroot/.config"
    echo 'BR2_PRIMARY_SITE="https://sources.buildroot.net"' >> "$SRC_DIR/buildroot/.config"
    PATH="$CLEAN_PATH" make -C "$SRC_DIR/buildroot" olddefconfig
}

if [ -n "$XSA_FILE" ]; then
echo "=== [1/7] Importing a pre-built XSA (Vivado not invoked) ==="
(
    set -e
    PLUTO_DIR="$SRC_DIR/hdl/projects/pluto"

    [ -r "$XSA_FILE" ] || { echo "ERROR: cannot read $XSA_FILE" >&2; exit 1; }

    # An .xsa is a zip. Check that before anything else, so a wrong file gets
    # one clear sentence instead of a confusing failure three stages later.
    unzip -l "$XSA_FILE" >/dev/null 2>&1 || {
        echo "ERROR: $XSA_FILE is not a readable zip archive." >&2
        echo "       An .xsa is a zip. Did you pass a .bit or a .bin by mistake?" >&2
        exit 1; }
    unzip -l "$XSA_FILE" | grep -q ' system_top.bit$' || {
        echo "ERROR: $XSA_FILE contains no system_top.bit." >&2
        echo "       It was probably exported without the bitstream. The export" >&2
        echo "       needs -include_bit; see docs/building-without-vivado.md" >&2
        exit 1; }

    # Refuse a platform for another part or another tool version rather than
    # let it reach the FSBL build and fail there, where the message is about a
    # missing peripheral rather than about the file you passed.
    sysdef="$(unzip -p "$XSA_FILE" sysdef.xml 2>/dev/null || true)"
    case "$sysdef" in
        *'PART="xc7z020clg400-2"'*) ;;
        "") echo "WARNING: $XSA_FILE has no sysdef.xml - cannot check the part" >&2 ;;
        *)  echo "ERROR: that XSA is not for this board's part (xc7z020clg400-2)." >&2
            echo "       It says: $(printf '%s' "$sysdef" | grep -o 'PART="[^\"]*"' | head -1)" >&2
            exit 1 ;;
    esac
    case "$sysdef" in
        *'Version="2022.2"'*|"") ;;
        *)  echo "ERROR: that XSA was written by a different tool version." >&2
            echo "       It says: $(printf '%s' "$sysdef" | grep -o 'Version="[^\"]*"' | head -1)" >&2
            echo "       This repository builds with 2022.2; mixing versions puts a" >&2
            echo "       mismatched ps7_init.c into the FSBL." >&2
            exit 1 ;;
    esac

    mkdir -p "$PLUTO_DIR/pluto.runs/impl_1"
    # Pointing --xsa at the tree's own platform is a reasonable thing to do
    # (rebuild from what is already here without re-running Vivado), and cp
    # refuses to copy a file onto itself.
    if [ "$XSA_FILE" -ef "$PLUTO_DIR/system_top.xsa" ]; then
        echo "    (already in place - reusing it where it is)"
    else
        cp -f "$XSA_FILE" "$PLUTO_DIR/system_top.xsa"
    fi

    # Stage [7/7] copies the bitstream out of the RUN directory, not out of
    # the XSA, so it has to land there. Verified byte-identical to a Vivado
    # run's own output.
    unzip -p "$XSA_FILE" system_top.bit > "$PLUTO_DIR/pluto.runs/impl_1/system_top.bit"
    [ -s "$PLUTO_DIR/pluto.runs/impl_1/system_top.bit" ] || {
        echo "ERROR: extracted system_top.bit is empty." >&2; exit 1; }

    # Delete rather than ignore. verify_output.sh reads these, and a report
    # left over from an earlier build would describe a bitstream it never saw
    # - which is exactly how a design gets vouched for by the wrong numbers.
    rm -f "$PLUTO_DIR/timing.rpt" "$PLUTO_DIR/utilization.rpt"

    mkdir -p "$OUT_DIR"
    {
        echo "# Written by build_all.sh --xsa. This bitstream was NOT built here."
        echo "source:   $XSA_FILE"
        echo "md5:      $(md5sum "$XSA_FILE" | cut -d' ' -f1)"
        echo "mtime:    $(date -r "$XSA_FILE" -Is 2>/dev/null || echo unknown)"
        echo "imported: $(date -Is)"
        echo "bitstream_md5: $(md5sum "$PLUTO_DIR/pluto.runs/impl_1/system_top.bit" | cut -d' ' -f1)"
        echo "# IP instances, read from the platform's own system.hwh - this"
        echo "# describes the BITSTREAM, unlike system_bd.tcl which describes"
        echo "# whatever source happens to be in the tree."
        unzip -p "$XSA_FILE" system.hwh 2>/dev/null \
            | grep -oE 'INSTANCE="[A-Za-z_0-9]+"' | sort -u | sed 's/^/ip: /' || true
    } > "$OUT_DIR/xsa-provenance.txt"

    bit_sz=$(stat -c %s "$PLUTO_DIR/pluto.runs/impl_1/system_top.bit")
    echo "    hardware platform: $PLUTO_DIR/system_top.xsa"
    echo "    bitstream:         $bit_sz bytes"
    echo "    provenance:        $OUT_DIR/xsa-provenance.txt"
    echo "    NOTE: this design was not implemented here, so there is no timing"
    echo "          report to check. ./scripts/verify_output.sh will say so."
)
else
# A from-source build must not leave the --xsa marker behind. It is written only
# by the import path, and nothing removed it - so a tree that had ever been built
# with --xsa carried xsa-provenance.txt into every later full build. That file is
# exactly what release.yml refuses to publish on, so a genuinely from-source
# release build would have been rejected for a stale breadcrumb. Found when the
# first real full build produced the correct stock bitstream (72 DSP48s, 11 896
# LUTs, WNS +0.205 ns) with yesterday's provenance file still sitting beside it.
rm -f "$OUT_DIR/xsa-provenance.txt"

echo "=== [1/7] Building HDL: synth -> impl -> bitstream -> hardware platform ==="
(
    source "$REPO_ROOT/tools/env-vivado.sh"
    cd "$SRC_DIR/hdl/projects/pluto"
    cp "$BUILD_ALL_DIR/build_hdl.tcl" .
    # The WBFM channel coefficients live in scripts/ (next to the generator
    # that produces them) and are copied in here rather than duplicated into
    # patches/, so there is one source of truth. system_bd.tcl references
    # this filename, so a rename has to happen in both places.
    cp "$BUILD_ALL_DIR/coefile_wbfm_102100.coe" .
    vivado -mode batch -source build_hdl.tcl -journal build_hdl.jou -log build_hdl.log
    echo "    Timing summary:"; grep -A3 "Design Timing Summary" timing.rpt | tail -2 || true
)
fi

echo "=== [1b/7] Building the cross-compilation toolchain (Linaro GCC 7.3-2018.05) ==="
if [ ! -x "$SRC_DIR/buildroot/output/host/bin/arm-linux-gnueabihf-gcc" ]; then
    buildroot_defconfig
    PATH="$CLEAN_PATH" make -C "$SRC_DIR/buildroot" toolchain
else
    echo "    already built, skipping"
fi
[ -x "$SRC_DIR/buildroot/output/host/bin/arm-linux-gnueabihf-gcc" ] || { echo "ERROR: toolchain build failed"; exit 1; }

# Build the FSBL from AMD's public embeddedsw. This was byte-identical to what
# Vitis's xsct produced when given the same compiler, and a board has booted the
# distro-toolchain build - see firmware/fsbl/README.md.
echo "=== [2/7] Building FSBL (embeddedsw) ==="
# The committed BSP headers describe ONE hardware design. If the block design
# has moved and they have not, the FSBL is built against the wrong peripheral
# addresses - a board that does not boot and prints nothing. This is the only
# place the check can run, because it needs the XSA, which never exists on a
# hosted runner.
"$REPO_ROOT/firmware/fsbl/hwcheck.py" --xsa "$SRC_DIR/hdl/projects/pluto/system_top.xsa" || {
    echo "ERROR: firmware/fsbl/generated/ does not match this hardware platform." >&2
    exit 1; }
# Build the FSBL with the DISTRO cross-compiler, explicitly, by taking every
# Xilinx directory off PATH for this one command.
#
# Without this the compiler depends on what else is installed. Vivado's own
# settings64.sh puts Vitis/2022.2/gnu/... on PATH, and docs/building.md tells
# you to source env-vivado.sh before building - so a machine WITH Vitis
# compiled the FSBL with Xilinx's gcc 11.2.0 while a machine without it used
# the distro's 10.3.1. Same sources, two different binaries, silently. The two
# are both good (11.2.0 is what reproduces Vitis byte-for-byte), but "which
# one you get" must not depend on an unrelated install.
#
# The distro toolchain is the one doctor.sh requires and the one a board has
# actually booted, so that is what this pins to.
FSBL_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$XILINX_DIR" | paste -sd: -)"
PATH="$FSBL_PATH" make -s -C "$REPO_ROOT/firmware/fsbl" BUILD="$SRC_DIR/hdl/fsbl/build"
FSBL_ELF="$SRC_DIR/hdl/fsbl/build/app/Debug/fsbl.elf"
[ -f "$FSBL_ELF" ] || { echo "ERROR: FSBL build failed"; exit 1; }

if [ "$HDL_ONLY" -eq 1 ]; then
    echo "=== [skipped] u-boot (--hdl-only) ==="
    [ -f "$SRC_DIR/u-boot-xlnx/u-boot" ] || { echo "ERROR: --hdl-only needs a previous full build; $SRC_DIR/u-boot-xlnx/u-boot is missing." >&2; exit 1; }
else
    echo "=== [3/7] Building u-boot ==="
    PATH="$TOOLCHAIN_PATH" make -C "$SRC_DIR/u-boot-xlnx" ARCH=arm CROSS_COMPILE=$CROSS_COMPILE zynq_pluto_defconfig
    PATH="$TOOLCHAIN_PATH" make -C "$SRC_DIR/u-boot-xlnx" ARCH=arm CROSS_COMPILE=$CROSS_COMPILE UBOOTVERSION="PlutoSDR"

fi

if [ "$HDL_ONLY" -eq 1 ]; then
    echo "=== [skipped] kernel (--hdl-only) ==="
    [ -f "$SRC_DIR/linux/arch/arm/boot/uImage" ] || { echo "ERROR: --hdl-only needs a previous full build; $SRC_DIR/linux/arch/arm/boot/uImage is missing." >&2; exit 1; }
else
    echo "=== [4/7] Building kernel: uImage + fishball device tree ==="
    PATH="$TOOLCHAIN_PATH" make -C "$SRC_DIR/linux" ARCH=arm CROSS_COMPILE=$CROSS_COMPILE zynq_pluto_defconfig
    PATH="$TOOLCHAIN_PATH" make -C "$SRC_DIR/linux" -j "$(nproc)" ARCH=arm CROSS_COMPILE=$CROSS_COMPILE uImage UIMAGE_LOADADDR=0x8000
    PATH="$TOOLCHAIN_PATH" DTC_FLAGS=-@ make -C "$SRC_DIR/linux" -j "$(nproc)" ARCH=arm CROSS_COMPILE=$CROSS_COMPILE zynq-pluto-sdr-fishball.dtb

fi

if [ "$HDL_ONLY" -eq 1 ]; then
    echo "=== [skipped] root filesystem (--hdl-only) ==="
    [ -f "$SRC_DIR/buildroot/output/images/rootfs.cpio.gz" ] || { echo "ERROR: --hdl-only needs a previous full build; $SRC_DIR/buildroot/output/images/rootfs.cpio.gz is missing." >&2; exit 1; }
else
    echo "=== [5/7] Building rootfs (auto-retries on git-archive hash drift) ==="
    # Upstream's top-level Makefile (which this script otherwise bypasses, to
    # keep Vivado's PATH pollution away from the u-boot/kernel/buildroot steps -
    # see the big comment above) does three things before "make -C buildroot
    # ... all" that our own direct buildroot invocation was skipping: write
    # buildroot/board/pluto/VERSIONS, run "make -C buildroot legal-info", and
    # turn that into buildroot/board/pluto/msd/LICENSE.html via
    # scripts/legal_info_html.sh. Without msd/LICENSE.html, the board's own
    # post-build.sh fails while generating the (immediately-discarded, and not
    # one of our 5 SD-card output files) boot.vfat MSD image, aborting the
    # whole buildroot run before rootfs.cpio.gz is produced.
    echo device-fw "$(cd "$SRC_DIR" && git describe --abbrev=4 --dirty --always --tags)" > "$SRC_DIR/buildroot/board/pluto/VERSIONS"
    for d in hdl buildroot linux u-boot-xlnx; do
        echo "$d $(cd "$SRC_DIR/$d" && git describe --abbrev=4 --dirty --always --tags)" >> "$SRC_DIR/buildroot/board/pluto/VERSIONS"
    done
    buildroot_defconfig
    # legal-info downloads sources, so it can hit the same git-archive hash drift
    # as the main build - run it through the same auto-repair wrapper rather than
    # letting it kill the build before the wrapper is ever reached.
    PATH="$CLEAN_PATH" "$BUILD_ALL_DIR/fix_and_retry_buildroot.sh" "$SRC_DIR" legal-info
    mkdir -p "$SRC_DIR/build"
    (cd "$SRC_DIR" && PATH="$CLEAN_PATH" scripts/legal_info_html.sh "PlutoSDR" "$SRC_DIR/buildroot/board/pluto/VERSIONS")
    cp "$SRC_DIR/build/LICENSE.html" "$SRC_DIR/buildroot/board/pluto/msd/LICENSE.html"

    # Buildroot's bundled host-m4 doesn't build under GCC >= 14's stricter C
    # defaults, so on a very new distro we have to point HOSTCC at an older
    # compiler. Don't hardcode that: Ubuntu 22.04 (the supported host) ships
    # GCC 11, which builds it fine and does not package gcc-13 at all - forcing
    # HOSTCC=gcc-13 there fails with "Unable to locate package gcc-13".
    HOST_CC_ARGS=()
    gcc_major="$(gcc -dumpversion 2>/dev/null | cut -d. -f1)"
    if [ "${gcc_major:-0}" -ge 14 ]; then
        if command -v gcc-13 >/dev/null 2>&1 && command -v g++-13 >/dev/null 2>&1; then
            echo "    default gcc is $gcc_major (too new for host-m4); using gcc-13 for host tools"
            HOST_CC_ARGS=(HOSTCC=gcc-13 HOSTCXX=g++-13)
        else
            echo "ERROR: your default gcc is $gcc_major, but Buildroot's host-m4 needs GCC <= 13." >&2
            echo "       Install gcc-13 and g++-13, or build on a host with an older default gcc." >&2
            exit 1
        fi
    else
        echo "    default gcc is ${gcc_major:-unknown}; using it for host tools"
    fi

    PATH="$CLEAN_PATH" "$BUILD_ALL_DIR/fix_and_retry_buildroot.sh" "$SRC_DIR" \
        "${HOST_CC_ARGS[@]}" \
        BUSYBOX_CONFIG_FILE="$SRC_DIR/buildroot/board/pluto/busybox-1.25.0.config" all
    if [ ! -f "$SRC_DIR/buildroot/output/images/rootfs.cpio.gz" ]; then
        echo "ERROR: buildroot rootfs build failed - see /tmp/buildroot_autoretry_*.log" >&2
        exit 1
    fi

fi

echo "=== [6/7] Generating uEnv.txt from the freshly-built u-boot ==="
mkdir -p "$OUT_DIR"
PATH="$TOOLCHAIN_PATH" CROSS_COMPILE=$CROSS_COMPILE "$SRC_DIR/scripts/get_default_envs.sh" > "$OUT_DIR/uEnv.txt"

echo "=== [7/7] Packaging SD-card files ==="
(
    source "$REPO_ROOT/tools/env-vivado.sh"
    cd "$OUT_DIR"
    cp "$FSBL_ELF" fsbl.elf
    cp "$SRC_DIR/hdl/projects/pluto/pluto.runs/impl_1/system_top.bit" system_top.bit
    cp "$SRC_DIR/u-boot-xlnx/u-boot" u-boot.elf
    cp "$SRC_DIR/linux/arch/arm/boot/uImage" uImage
    cp "$SRC_DIR/linux/arch/arm/boot/dts/zynq-pluto-sdr-fishball.dtb" devicetree.dtb
    # mkimage stamps the current time into u-boot's 64-byte header, so this
    # file came out different on every build even when --hdl-only left the
    # root filesystem completely untouched - the payload was always identical,
    # only the header moved. Pin the stamp to the rootfs's own mtime so the
    # image is as old as its contents and two builds of the same source agree.
    # An externally set SOURCE_DATE_EPOCH wins, as reproducible-builds expects.
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(stat -c %Y "$SRC_DIR/buildroot/output/images/rootfs.cpio.gz")}" \
    mkimage -A arm -T ramdisk -C gzip -d "$SRC_DIR/buildroot/output/images/rootfs.cpio.gz" uramdisk.image.gz

    cp "$BUILD_ALL_DIR/boot.bif" .
    bootgen -image boot.bif -arch zynq -o BOOT.bin -w
    rm -f fsbl.elf system_top.bit u-boot.elf boot.bif  # intermediate, not needed on the SD card
)

echo "=== Sanity-checking output files ==="
for f in BOOT.bin devicetree.dtb uEnv.txt uImage uramdisk.image.gz; do
    path="$OUT_DIR/$f"
    if [ ! -s "$path" ]; then
        echo "ERROR: $path is missing or empty - a step above silently produced nothing usable." >&2
        exit 1
    fi
done
# BOOT.bin (FSBL + bitstream + U-Boot) should always be multiple MB; a
# truncated file here usually means bootgen failed partway without a
# nonzero exit code.
boot_bin_size=$(stat -c %s "$OUT_DIR/BOOT.bin")
if [ "$boot_bin_size" -lt 1000000 ]; then
    echo "ERROR: $OUT_DIR/BOOT.bin is only $boot_bin_size bytes - expected several MB. bootgen likely failed silently." >&2
    exit 1
fi

echo
echo "=== Done. SD-card files are in: $OUT_DIR ==="
ls -la "$OUT_DIR"
echo
echo "Copy all five files (BOOT.bin, devicetree.dtb, uEnv.txt, uImage,"
echo "uramdisk.image.gz) onto the SD card's single FAT32 partition."
