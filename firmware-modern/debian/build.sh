#!/bin/bash
# Build the Debian armhf root filesystem for this board, as a tarball.
#
#     # run from: the repo root
#     ./devkit build --target modern --rootfs-only    # writes rootfs.tar
#
# Needs podman (or docker) and armhf emulation registered with the kernel. If
# the emulation is missing, this registers it by itself from a container
# (tonistiigi/binfmt), which needs a rootful runtime: docker, or sudo podman.
# Rootless podman cannot, so install it from your distro instead:
#     Debian/Ubuntu:  sudo apt install qemu-user-static binfmt-support
#     Arch:           sudo pacman -S qemu-user-static qemu-user-static-binfmt
#
# This does NOT touch any SD card. write-card.sh does that, separately and
# deliberately, because the two failure modes are completely different: a bad
# tarball wastes ten minutes, a bad card write costs a card-reader trip.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE=fishball-debian-armhf
OUT="$HERE/rootfs.tar"

RT=$(command -v podman || command -v docker) || { echo "need podman or docker" >&2; exit 1; }

armhf_ok() {
    "$RT" run --rm --platform linux/arm/v7 docker.io/arm32v7/debian:trixie \
        /bin/true 2>/dev/null
}

if ! armhf_ok; then
    echo "=== no armhf emulation on the kernel; registering it from a container ==="
    # Registers a qemu-arm binfmt_misc handler (persistent "F" flag, so it
    # keeps working for containers after this helper exits). Needs a rootful
    # runtime: plain docker as a user in the docker group, or sudo podman.
    # (Contributed by @MrMati, #9.)
    if "$RT" run --privileged --rm docker.io/tonistiigi/binfmt --install arm \
            && armhf_ok; then
        echo "=== armhf emulation ready ==="
    else
        echo "ERROR: cannot run armhf containers, and automatic registration" >&2
        echo "       via tonistiigi/binfmt did not take (rootless podman cannot)." >&2
        echo "       Install the emulation from your distro, then retry:" >&2
        echo "           Debian/Ubuntu:  sudo apt install qemu-user-static binfmt-support" >&2
        echo "           Arch:           sudo pacman -S qemu-user-static qemu-user-static-binfmt" >&2
        exit 1
    fi
fi

echo "=== building $IMAGE (armhf, under emulation - this is slow) ==="
# What this build is, for /opt/VERSIONS inside the image. The container cannot
# reach the host's git, so it is computed here and passed in. `|| echo unknown`
# because a tarball download with no .git must still build.
FW_VERSION="$(cd "$HERE" && git describe --abbrev=8 --dirty --always --tags 2>/dev/null || echo unknown)"
echo "=== building $IMAGE  (device-fw $FW_VERSION) ==="

"$RT" build --platform linux/arm/v7 --build-arg "FW_VERSION=$FW_VERSION" \
      -t "$IMAGE" -f "$HERE/Containerfile" "$HERE"

echo "=== exporting the root filesystem ==="
cid=$("$RT" create --platform linux/arm/v7 "$IMAGE" /bin/true)
trap '"$RT" rm -f "$cid" >/dev/null 2>&1 || true' EXIT
"$RT" export "$cid" > "$OUT"

echo
echo "  $OUT  $(du -h "$OUT" | cut -f1)"
echo "  $(tar tf "$OUT" | wc -l) entries"
echo
echo "Next: sudo ./devkit write-card --target modern /dev/sdX"
echo "      (it shows you what it is about to do, and refuses anything that is"
echo "      not removable)"
