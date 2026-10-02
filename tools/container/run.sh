#!/bin/bash
# Run a devkit command inside the pinned Vivado 2022.2 environment.
#
#   ./devkit container build-image        build (or rebuild) the image
#   ./devkit container install <bin>      install Vivado 2022.2 itself, inside
#                                         the container, onto the host
#   ./devkit container doctor             run ./devkit doctor inside it
#   ./devkit container build --target factory --hdl-only
#                                         run a build inside it
#   ./devkit container shell              an interactive shell inside it
#
# Vivado itself is not in the image. /tools/Xilinx is bind-mounted read-only,
# which keeps the image about 1 GB instead of 45 and means the toolchain you
# test is the toolchain you already have.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${DEVKIT_IMAGE:-fishball7020-build:2022.2}"
XILINX_DIR="${XILINX_DIR:-/tools/Xilinx}"
# Vivado writes ~/.Xilinx; give it somewhere that persists between runs without
# putting container state in the host's home directory.
CHOME="$HERE/firmware/.container-home"

runtime() {
    if   command -v podman >/dev/null 2>&1; then echo podman
    elif command -v docker >/dev/null 2>&1; then echo docker
    else echo "ERROR: neither podman nor docker found" >&2; exit 1; fi
}
RT="$(runtime)"

if [ "${1:-}" = "build-image" ]; then
    exec "$RT" build -t "$IMAGE" -f "$HERE/tools/container/Containerfile" "$HERE/tools/container"
fi

if ! "$RT" image exists "$IMAGE" 2>/dev/null && ! "$RT" image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "ERROR: image '$IMAGE' not built yet - run: ./devkit container build-image" >&2
    exit 1
fi
# -t only when there really is a terminal. Asking for one when stdin is a pipe
# (a script, CI, an agent) makes podman block with no output at all, which
# looks exactly like the build hanging.
TTY=()
[ -t 0 ] && TTY=(-i -t)

if [ "${1:-}" = "install" ]; then
    shift
    BIN="${1:-}"
    # Drop the installer path too, so "$@" below is only the extra arguments
    # meant for xsetup - otherwise the installer path is passed to it twice.
    [ $# -gt 0 ] && shift
    if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
        echo "usage: ./devkit container install /path/to/Xilinx_Unified_2022.2_*.bin" >&2
        echo "Download it from AMD first - it is behind an account login, so" >&2
        echo "this cannot fetch it for you." >&2
        exit 2
    fi
    # The bootstrap problem this solves: the container exists because the host
    # is too new to run Vivado 2022.2, and the Xilinx installer is the same
    # Java/GTK application with the same requirements. So it runs in here too,
    # writing OUT to the host through a read-write mount - the one time
    # $XILINX_DIR is not mounted read-only.
    if [ ! -d "$XILINX_DIR" ] || [ ! -w "$XILINX_DIR" ]; then
        echo "ERROR: $XILINX_DIR must exist and be writable by you." >&2
        echo "Rootless podman maps the container's root to your own user, so a" >&2
        echo "root-owned directory cannot be written even from 'root' inside." >&2
        echo "  sudo mkdir -p $XILINX_DIR && sudo chown \"$USER\" $XILINX_DIR" >&2
        exit 1
    fi
    mkdir -p "$CHOME"
    BIN_DIR="$(cd "$(dirname "$BIN")" && pwd)"
    # Extract explicitly, then run xsetup from where it landed. Two ways this
    # goes wrong, both reported as a bare "Extraction failed":
    #   - running the .bin in place, because it unpacks relative to the working
    #     directory and the directory holding the installer is read-only here;
    #   - unpacking onto the container's own overlay (/tmp), which rootless
    #     podman mounts with userxattr and which the installer's tar does not
    #     survive - despite having the whole disk free.
    # A bind mount is neither, so the work directory is one of those.
    exec "$RT" run "${TTY[@]}" --rm \
        -v "$XILINX_DIR:$XILINX_DIR" \
        -v "$BIN_DIR:$BIN_DIR:ro" \
        -v "$CHOME:/home/builder" -e HOME=/home/builder \
        ${DISPLAY:+-e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix} \
        -w /home/builder "$IMAGE" bash -c '
            echo "Extracting the installer (about 720 MB, once)..."
            rm -rf /home/builder/installer
            mkdir -p /home/builder/installer
            # Its exit code is not worth believing. The self-extractor trips
            # its own signal trap on the way out and reports "Extraction
            # failed." with status 143 having extracted everything correctly,
            # so check for the thing we came for instead.
            bash "$1" --noexec --target /home/builder/installer >/dev/null 2>&1 || true
            if [ ! -x /home/builder/installer/xsetup ]; then
                echo "ERROR: extraction really did fail - no xsetup produced." >&2
                exit 1
            fi
            cd /home/builder/installer
            exec ./xsetup "${@:2}"
        ' _ "$BIN_DIR/$(basename "$BIN")" "$@"
fi

# Vivado is mounted only when it exists. It used to be REQUIRED for every container
# command, which made the container useless to exactly the people it most helps:
# the modern target has no Vivado path at all, and on a machine with no ARM Linux
# cross-compiler the container is how it builds (#9). A command that genuinely
# needs Vivado - a factory build without --xsa - still stops in its own preflight,
# with a message about Vivado rather than about this directory.
HAVE_XILINX=0
if [ -d "$XILINX_DIR" ]; then
    HAVE_XILINX=1
else
    echo "note: $XILINX_DIR not found - running without Vivado. Fine for --xsa and" >&2
    echo "      --target modern builds; a factory build from source needs Vivado" >&2
    echo "      (./devkit container install <installer.bin>)." >&2
fi

mkdir -p "$CHOME"

# The repo is mounted at ITS OWN absolute path, not at /work. Vivado stores
# absolute paths inside pluto.xpr, so a project created on the host and one
# created in the container are only interchangeable if the path matches. Get
# this wrong and --hdl-only silently rebuilds against a project it cannot find.
# XILINX_DIR is passed in as well as mounted: doctor.sh, build_all.sh and
# env-vivado.sh read it to find Vivado, so mounting alone would leave them
# looking at /tools/Xilinx inside a container that has no such directory.
#
# /run/udev is mounted because Vivado's licence manager fingerprints the host
# through libudev. With no udev database in the container,
# udev_enumerate_scan_devices() returns a pointer that malloc_usable_size()
# then underflows on, and Vivado dies mid-synthesis with
# "tcmalloc: large alloc 115875935977472 bytes" and a SIGSEGV whose stack
# names neither udev nor licensing. Read-only is enough; it only reads.
ARGS=(
    --rm
    -v "$HERE:$HERE"
    -e "XILINX_DIR=$XILINX_DIR"
    -v "$CHOME:/home/builder"
    -v /run/udev:/run/udev:ro
    -e HOME=/home/builder
    -w "$HERE"
)
# The ./devkit inside must pick the same default target as the one outside.
[ -n "${DEVKIT_TARGET:-}" ] && ARGS+=(-e "DEVKIT_TARGET=$DEVKIT_TARGET")
[ "$HAVE_XILINX" -eq 1 ] && ARGS+=(-v "$XILINX_DIR:$XILINX_DIR:ro")

# --xsa FILE: resolve it HERE, against the directory you typed it in, and mount the
# directory it lives in if that is outside the repo. The container sees only the
# repo, and works from its root, so both "--xsa ~/fishball-platform.xsa" - the
# location the docs themselves use - and a relative path typed from a
# subdirectory used to fail inside it with "cannot read". Read-only: the build
# only reads the platform.
_fwd=(); _takex=0
for _a in "$@"; do
    if [ "$_takex" -eq 1 ]; then
        _takex=0
        case "$_a" in /*) ;; *) _a="$PWD/$_a" ;; esac
    elif [ "$_a" = "--xsa" ]; then
        _takex=1
    else
        case "$_a" in --xsa=/*) ;; --xsa=*) _a="--xsa=$PWD/${_a#--xsa=}" ;; esac
    fi
    case "$_a" in
        --xsa=*) _x="${_a#--xsa=}" ;;
        /*.xsa)  _x="$_a" ;;
        *)       _x="" ;;
    esac
    if [ -n "$_x" ] && [ -f "$_x" ]; then
        # The FILE, read-only - not its directory: for ~/platform.xsa that would
        # hand the container all of $HOME, .ssh included.
        _xabs="$(cd "$(dirname "$_x")" && pwd)/$(basename "$_x")"
        case "$_xabs" in
            "$HERE"/*) ;;
            *) ARGS+=(-v "$_xabs:$_xabs:ro") ;;
        esac
    fi
    _fwd+=("$_a")
done
set -- ${_fwd[@]+"${_fwd[@]}"}
# Rootless podman already maps the container's root to the invoking user, so
# files land owned by you without --userns=keep-id. Leaving keep-id off also
# avoids the permission oddities it creates inside bind mounts, and Vivado got
# measurably further without it. Docker has no such mapping and must be told.
if [ "$RT" != podman ]; then ARGS+=(--user "$(id -u):$(id -g)"); fi

# Where the board is, resolved HERE and passed in.
#
# The container can reach the board perfectly well - TCP to iiod and ssh both
# work on the default network - but it cannot NAME it. A .local address is mDNS,
# the image has no nss-mdns and no avahi, so board_addr.py exhausts fishball.local
# and friends inside and falls through to its last candidate, the USB gadget at
# 192.168.2.1 - which is not connected when the board is on Ethernet. The result
# was doctor reporting "no board" with the board plainly up.
#
# So resolve on the host, where mDNS works, and hand the answer over. An explicit
# $BOARD is forwarded untouched; otherwise --check probes and we forward only an
# address that actually answered, leaving "no board" to mean what it says.
_board_at="${BOARD:-}"
if [ -z "$_board_at" ]; then
    _board_at="$(python3 "$HERE/tools/board_addr.py" --check 2>/dev/null)" || _board_at=""
fi
if [ -n "$_board_at" ]; then
    # Forward an ADDRESS, never a name. board_addr.py prefers names - that is
    # the point of it - but a name is exactly what cannot be looked up in here,
    # so resolve it on the way through. IPv4 on purpose: the container's default
    # network carries it, and the board's IPv6 is a global SLAAC address that
    # rootless podman does not route.
    _board_ip="$(getent ahostsv4 "$_board_at" 2>/dev/null | awk 'NR==1{print $1}')"
    [ -n "$_board_ip" ] || _board_ip="$_board_at"      # already an address
    ARGS+=(-e "BOARD=$_board_ip")
    # Keep the name working too, so ssh/scp inside a `container shell` behave
    # the way they do on the host.
    case "$_board_at" in
        *[!0-9.]*) ARGS+=(--add-host "$_board_at:$_board_ip") ;;
    esac
fi

# Pass the display through when there is one, so the block design can be opened
# in the container too. Nothing in the build needs a display - it is Vivado's
# GUI or nothing, which is why the image carries GTK2 and no longer Xvfb.
if [ -n "${DISPLAY:-}" ] && [ -S /tmp/.X11-unix/X"${DISPLAY#*:}" ] 2>/dev/null; then
    ARGS+=(-e "DISPLAY=$DISPLAY" -v /tmp/.X11-unix:/tmp/.X11-unix)
elif [ -n "${DISPLAY:-}" ]; then
    ARGS+=(-e "DISPLAY=$DISPLAY" -v /tmp/.X11-unix:/tmp/.X11-unix)
fi

if [ "${1:-}" = "shell" ]; then
    shift
    exec "$RT" run "${TTY[@]}" "${ARGS[@]}" "$IMAGE" bash "$@"
fi

exec "$RT" run "${TTY[@]}" "${ARGS[@]}" "$IMAGE" ./devkit "$@"
