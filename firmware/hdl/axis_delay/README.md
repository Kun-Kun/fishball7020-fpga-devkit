# AXI4-Stream delay line

`axis_delay` delays a complete AXI4-Stream beat, including TDATA, TKEEP,
TSTRB, TLAST, TUSER, TID, and TDEST. Set `DELAY_CYCLES` to a nonnegative
integer; zero is a combinational pass-through. `DATA_WIDTH`, `KEEP_WIDTH`,
`USER_WIDTH`, `ID_WIDTH`, and `DEST_WIDTH` configure the corresponding signal
widths. All widths must be positive. `KEEP_WIDTH` defaults to the number of
bytes needed for `DATA_WIDTH`; TSTRB uses the same width.
`ENABLE_SIDEBANDS=0` stores only TDATA and emits all-ones TKEEP/TSTRB, zero
TLAST/TUSER/TID/TDEST. Use this for streams that carry no sidebands.

When the downstream interface is continuously ready, a beat appears at the
output after exactly `DELAY_CYCLES` rising clock edges. A stalled downstream
interface can extend the latency; the elastic stages hold every beat and apply
backpressure upstream. Reset is synchronous and active high. Assert reset
before using a nonzero delay; output payload is meaningful only when TVALID is
high. It clears the registers on a rising edge and suppresses both handshakes
while asserted.

`./devkit setup --target factory` copies this IP into the generated ADI HDL
library. The Makefile and Tcl file package it for Vivado IP Integrator.
