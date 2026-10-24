# Local FPGA HDL

This directory is the maintained source for custom FPGA IP. `./devkit setup
--target factory` overlays every IP directory here into `firmware/src/hdl/library/`
after it applies the numbered upstream patches.

Keep upstream integration changes in `firmware/patches/`: library registration,
project dependencies, and block-design wiring. Do not edit the overlay copy in
`firmware/src`; setup replaces it from this directory.
