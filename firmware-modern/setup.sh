#!/bin/bash
# Clone Analog Devices' Linux at the pinned commit, drop this board's device
# tree and kernel configuration in, and apply the nine driver patches.
#
# Run once before building, or after deleting src/ to start clean. This is what
# CI runs too, so a tree built by hand and a tree built by CI are the same tree.
#
#   # run from: firmware-modern/
#   ./setup.sh
#
# Unlike main's setup.sh this clones ONE repository - the kernel. There is no
# monorepo here: the rootfs still comes from main's Buildroot, the bitstream is
# a hard invariant on this branch, and U-Boot is untouched.

set -euo pipefail
FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$FW_DIR/src/linux"

UPSTREAM_URL="https://github.com/analogdevicesinc/linux.git"

# Pinned to the exact commit every measurement in baseline/ was taken against.
# ADI's main moves daily and this is a vendor fork, so tracking its HEAD means
# the patches can stop applying between one clone and the next with nothing in
# this repo having changed. 2026-09-24, Linux 6.12.0.
UPSTREAM_COMMIT="947298737646475ebb557be24d6ee9fc7901e0a9"

if [ -d "$SRC_DIR/.git" ]; then
    echo "=== $SRC_DIR already exists - skipping clone. Delete it first for a clean setup. ==="
    current="$(cd "$SRC_DIR" && git rev-parse HEAD)"
    if [ "$current" != "$UPSTREAM_COMMIT" ]; then
        echo "NOTE: $SRC_DIR is at $current, not the pinned $UPSTREAM_COMMIT."
        echo "      That is expected once the patches are applied as commits;"
        echo "      it is a problem if you have not touched the tree."
    fi
else
    # A depth-1 fetch of one commit, not a clone: the full history is ~5 GB and
    # nothing here needs it. github.com allows fetching an arbitrary SHA, so the
    # pin does not have to be a branch tip.
    echo "=== Fetching $UPSTREAM_COMMIT from $UPSTREAM_URL (shallow) ==="
    mkdir -p "$SRC_DIR"
    (cd "$SRC_DIR"
     git init --quiet
     git remote add origin "$UPSTREAM_URL" 2>/dev/null || true
     git fetch --quiet --depth 1 origin "$UPSTREAM_COMMIT" || {
        echo "ERROR: could not fetch $UPSTREAM_COMMIT." >&2
        echo "       ADI rewrites history on main from time to time. If the commit" >&2
        echo "       is genuinely gone, the patches will need rebasing onto a new" >&2
        echo "       pin - see patches/README.md for what that cost last time." >&2
        exit 1
     }
     git checkout --quiet FETCH_HEAD)
fi

echo "=== Installing the board's device tree and kernel configuration ==="
# Both are plain drop-ins rather than patches, deliberately: the .dts is a new
# file that overlays ADI's zynq-pluto-sdr.dtsi, and the defconfig is a new file
# too, so neither needs to carry context that can rot.
install -m 644 "$FW_DIR/dts/zynq-pluto-sdr-fishball.dts" \
    "$SRC_DIR/arch/arm/boot/dts/xilinx/"
install -m 644 "$FW_DIR/config/fishball_defconfig" "$SRC_DIR/arch/arm/configs/"

echo "=== Applying patches ==="
# Patches STACK - 0004 -> 0005 -> 0012 and 0004 -> 0015 -> 0017 each edit the
# lines the one before added - so they must go on in filename order, and
# "git apply --check --reverse" on an earlier patch fails once a later one is
# on top. That makes patch-by-patch checking report a fully patched tree as
# broken. Record which patches were applied instead, one "sha256  name" line
# each; main's setup.sh learned this the same way.
STAMP="$SRC_DIR/.devkit-patches-applied"
patch_line() { printf '%s  %s\n' "$(sha256sum "$1" | cut -d" " -f1)" "$(basename "$1")"; }

# A tree that was patched some other way - by hand, or as one commit per patch
# while rebasing - has no stamp and is perfectly fine. Recognise it before the
# loop below declares it broken: if the LAST patch reverses cleanly then the
# whole series is on, in order, because nothing sits on top of it.
LAST_PATCH="$(ls "$FW_DIR"/patches/*.patch | sort | tail -1)"
if [ -n "$LAST_PATCH" ] && (cd "$SRC_DIR" && git apply --check --reverse "$LAST_PATCH" 2>/dev/null); then
    if [ ! -f "$STAMP" ] || ! grep -q "  $(basename "$LAST_PATCH")$" "$STAMP" 2>/dev/null; then
        echo "  series already applied - recording a per-patch stamp"
        : > "$STAMP"
        for p in "$FW_DIR"/patches/*.patch; do patch_line "$p" >> "$STAMP"; done
    fi
fi

applied=0
skipped=0
for p in "$FW_DIR"/patches/*.patch; do
    name=$(basename "$p")
    if [ -f "$STAMP" ] && grep -qxF "$(patch_line "$p")" "$STAMP"; then
        skipped=$((skipped + 1))
        continue
    fi
    echo "  -> $name"
    if (cd "$SRC_DIR" && git apply --check "$p" 2>/dev/null); then
        (cd "$SRC_DIR" && git apply "$p")
        applied=$((applied + 1))
    elif (cd "$SRC_DIR" && git apply --check --reverse "$p" 2>/dev/null); then
        echo "     already applied - recording it"
    else
        echo "ERROR: $name does not apply cleanly, and is not already applied." >&2
        echo "       Nothing in src/ is yours - it is fetched and patched by this" >&2
        echo "       script - so the surest fix is to start clean:" >&2
        echo "           rm -rf \"$SRC_DIR\" && ./setup.sh" >&2
        exit 1
    fi
    patch_line "$p" >> "$STAMP"
done

if [ "$applied" -eq 0 ]; then
    echo "  all $skipped patch(es) already applied - nothing to do"
else
    echo "  $applied applied, $skipped already there"
fi

cat <<EOF

=== Ready ===
  # run from: firmware-modern/src/linux
  CROSS=../../../firmware/src/buildroot/output/host/bin/arm-linux-gnueabihf-
  make ARCH=arm CROSS_COMPILE=\$CROSS fishball_defconfig
  make ARCH=arm CROSS_COMPILE=\$CROSS uImage LOADADDR=0x8000 -j\$(nproc)
  make ARCH=arm CROSS_COMPILE=\$CROSS DTC_FLAGS=-@ xilinx/zynq-pluto-sdr-fishball.dtb

The cross toolchain above is main's Buildroot output. Any arm-linux-gnueabihf
GCC will do; 6.12 builds with both that 2018-era 7.3 and a current one.
EOF
