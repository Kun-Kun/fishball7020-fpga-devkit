# Source this instead of settings64.sh directly:
#   source tools/env-vivado.sh
#
# A default Ubuntu 22.04 install does not ship libtinfo5/libncurses5/libssl1.1, which
# Vivado 2025.1's bundled binaries require at runtime. This prepends
# locally-extracted copies of those libraries to LD_LIBRARY_PATH so
# Vivado can find them without touching the rest of the OS.
#
# Only when the system does not have them. The bundled copies were extracted
# on 22.04 and link against GLIBC_2.33, so forcing them onto an older
# distribution - an older OS, say, or the build container -
# breaks Vivado with a confusing "librdi_commontasks.so: GLIBC_2.33 not found"
# that names the wrong library. Where the distro ships libtinfo.so.5 itself,
# use it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! ldconfig -p 2>/dev/null | grep -q 'libtinfo\.so\.5'; then
    export LD_LIBRARY_PATH="$SCRIPT_DIR/legacy-libs/libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
# XILINX_DIR is the release root, containing Vivado/ and Vitis/. Override it
# for an installation outside the standard locations.
source "$SCRIPT_DIR/xilinx-path.sh"
[ -r "$VIVADO_DIR/settings64.sh" ] || {
    echo "ERROR: Vivado 2025.1 was not found at $VIVADO_DIR." >&2
    echo "       Set XILINX_DIR to the 2025.1 release directory." >&2
    return 1 2>/dev/null || exit 1
}
# AMD's 2025.1 settings script expands PYTHONPATH without a default. The devkit
# deliberately uses `set -u`, so source it with nounset scoped off and restore
# the caller's shell options immediately afterwards.
_fishball_had_nounset=0
case $- in *u*) _fishball_had_nounset=1; set +u ;; esac
source "$VIVADO_DIR/settings64.sh"
[ "$_fishball_had_nounset" -eq 1 ] && set -u
unset _fishball_had_nounset
