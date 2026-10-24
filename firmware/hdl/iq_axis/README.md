# iq_axis

`iq_axis` converts one receive-channel pair of signed 16-bit parallel I/Q
samples into a 32-bit AXI4-Stream master. `TDATA` is `{Q[15:0], I[15:0]}`.

The input has no backpressure. One elastic beat absorbs a downstream stall;
`overflow` pulses when a valid sample is rejected. The Pluto design instantiates
this IP once for each RX channel.
