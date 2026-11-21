# RX beat source selector

One `axis_rx_select` instance per RX chooses ADC samples directly for a DC
TX carrier or the RX × conjugate(selected TX) multiplier result for a
tone/chirp probe. Both instances use EMIO bit 31 (`rx2_raw_bypass`, Linux GPIO
offset 85). The bit is changed only between captures and resets to multiplier
mode.

Raw RX samples continue to feed each multiplier during bypass. That keeps
the shared TX reference draining so the cyclic TX DMA cannot stall.
The unused multiplier result is drained. A one-register fanout tracks the
two consumers independently and preserves AXI backpressure.

The CMPY product passes through at full 33-bit component precision in an
80-bit AXIS word. In raw mode, each signed 16-bit sample is shifted into the
same Q17 position so the downstream gain stage can use one conversion rule.
