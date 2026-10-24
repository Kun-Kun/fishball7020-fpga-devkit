# axis_iq

`axis_iq` converts one 32-bit AXI4-Stream slave into signed 16-bit parallel
I/Q transmit samples. `TDATA` is `{Q[15:0], I[15:0]}`.

One prefetched AXIS beat is retained so a synchronous transmit request sees a
previously accepted sample. `underflow` pulses when the radio requests a sample
before one is available. The Pluto design instantiates this IP once for each TX
channel.
