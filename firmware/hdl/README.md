# Local FPGA HDL

This directory is the maintained source for custom FPGA IP. `./devkit setup
--target factory` overlays every IP directory here into `firmware/src/hdl/library/`
after it applies the numbered upstream patches.

Keep upstream integration changes in `firmware/patches/`: library registration,
project dependencies, and block-design wiring. Do not edit the overlay copy in
`firmware/src`; setup replaces it from this directory.

`util_fir_dec` exposes a configurable `NUM_OF_CHANNELS` parameter. Its current
block-design instance sets the value to 2 for the two RX streams.
