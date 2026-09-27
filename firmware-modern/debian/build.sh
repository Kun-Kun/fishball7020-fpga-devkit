#!/bin/bash
# Build the Debian armhf root filesystem for this board, as a tarball.
#
#     # run from: firmware-modern/debian/
#     ./build.sh                  # writes rootfs.tar
#
# Needs podman (or docker) and armhf emulation registered with the kernel:
#     sudo apt install podman qemu-user-static binfmt-support
#     arch-test armhf          # must say "ok"
#
# This does NOT touch any SD card. write-card.sh does that, separately and
# deliberately, because the two failure modes are completely different: a bad
# tarball wastes ten minutes, a bad card write costs a card-reader trip.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE=fishball-debian-armhf
OUT="$HERE/rootfs.tar"

RT=$(command -v podman || command -v docker) || { echo "need podman or docker" >&2; exit 1; }

if ! "$RT" run --rm --platform linux/arm/v7 docker.io/arm32v7/debian:trixie \
        /bin/true 2>/dev/null; then
    echo "ERROR: cannot run armhf containers." >&2
    echo "       sudo apt install qemu-user-static binfmt-support, then:" >&2
    echo "           arch-test armhf" >&2
    exit 1
fi

echo "=== building $IMAGE (armhf, under emulation - this is slow) ==="
"$RT" build --platform linux/arm/v7 -t "$IMAGE" -f "$HERE/Containerfile" "$HERE"

echo "=== exporting the root filesystem ==="
cid=$("$RT" create --platform linux/arm/v7 "$IMAGE" /bin/true)
trap '"$RT" rm -f "$cid" >/dev/null 2>&1 || true' EXIT
"$RT" export "$cid" > "$OUT"

echo
echo "  $OUT  $(du -h "$OUT" | cut -f1)"
echo "  $(tar tf "$OUT" | wc -l) entries"
echo
echo "Next: sudo ./write-card.sh /dev/sdX     (it will show you what it is about"
echo "      to do and refuse anything that is not removable)"
