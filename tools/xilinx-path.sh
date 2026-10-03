#!/bin/bash
# Locate the root of a Vivado/Vitis 2025.1 installation.
#
# XILINX_DIR names the release directory itself, whose immediate children are
# Vivado/ and Vitis/.  That is the layout of the current unified installer:
#
#   /home/alice/xilinx/2025.1/Vivado
#   /home/alice/xilinx/2025.1/Vitis
#
# Set XILINX_DIR explicitly to use another location.  The fallbacks cover the
# local installer location and the path used in the build-container docs.

if [ -z "${XILINX_DIR:-}" ]; then
    for _fishball_xilinx_dir in "$HOME/xilinx/2025.1" /tools/Xilinx/2025.1; do
        if [ -x "$_fishball_xilinx_dir/Vivado/bin/vivado" ]; then
            XILINX_DIR="$_fishball_xilinx_dir"
            break
        fi
    done
fi

export XILINX_DIR="${XILINX_DIR:-/tools/Xilinx/2025.1}"
export VIVADO_DIR="$XILINX_DIR/Vivado"
export VITIS_DIR="$XILINX_DIR/Vitis"

if [ "${1:-}" = "--require-vivado" ] && [ ! -x "$VIVADO_DIR/bin/vivado" ]; then
    echo "ERROR: Vivado 2025.1 was not found at $VIVADO_DIR." >&2
    echo "       Set XILINX_DIR to the 2025.1 release directory." >&2
    exit 1
fi
