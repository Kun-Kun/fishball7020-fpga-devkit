# Local FPGA HDL

This directory is the maintained source for custom FPGA IP. `./devkit setup
--target factory` overlays every IP directory here into `firmware/src/hdl/library/`
after it applies the numbered upstream patches.

Keep upstream integration changes in `firmware/patches/`: library registration,
project dependencies, and block-design wiring. Do not edit the overlay copy in
`firmware/src`; setup replaces it from this directory.

`util_fir_dec` exposes a configurable `NUM_OF_CHANNELS` parameter. Its current
block-design instance sets the value to 2 for the two RX streams.

`tx_fir_interpolator` accepts two 32-bit complex AXI4-Stream inputs and emits
two 32-bit complex streams. Each beat is `{Q[15:0], I[15:0]}`; independent
16-bit FIR Compiler cores process I and Q with the same interpolation filter.
The block-design instance sits between `S_AXIS_TX0/1` and the per-channel
`axis_iq` adapters. Its `active` input selects interpolation when high and a
ready/valid bypass when low. `up_dac_gpio_out[2]` selects the custom AXIS TX
source at the DAC; zero keeps the legacy DMA path. The interpolator is clocked
by the AD9361 sample clock and uses the local `coefile_int.coe` coefficients.
