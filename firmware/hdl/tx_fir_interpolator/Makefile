####################################################################################
## Copyright (c) 2026 Fishball
### SPDX short identifier: BSD-1-Clause
####################################################################################

LIBRARY_NAME := tx_fir_interpolator

GENERIC_DEPS += tx_fir_interpolator.v
GENERIC_DEPS += sync_bits.v
GENERIC_DEPS += coefile_int.coe

XILINX_DEPS += tx_fir_interpolator_ip.tcl

include ../scripts/library.mk

.PHONY: sim-test
sim-test:
	@command -v iverilog >/dev/null || { echo "sim-test needs iverilog" >&2; exit 1; }
	@sim_out=$$(mktemp); trap 'rm -f "$$sim_out"' EXIT; \
	  iverilog -g2012 -s tx_fir_interpolator_tb -o "$$sim_out" \
	    tx_fir_interpolator.v sync_bits.v tb/fir_interpolator_mock.v \
	    tb/tx_fir_interpolator_tb.v && vvp "$$sim_out"
