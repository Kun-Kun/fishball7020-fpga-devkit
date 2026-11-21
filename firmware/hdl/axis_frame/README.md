# AXI FMCW frame marker

Place `axis_frame` after the RX FIR and before cpack. The existing ramp gate
stays before the FIR. `bypass=1` passes ordinary continuous IQ unchanged.
With `bypass=0`, rising `start` emits `MAGIC START sequence`, then the FIR IQ
words. A short asynchronous `stop` pulse is latched; after 512 stream clocks
without another FIR word the core emits
`MAGIC END sequence sample_count xor_checksum`. The wait lets the FIR drain.
Outside the frame, one zero filler word is emitted every 128 clocks so the
IIO DMA can complete partial refills. The host ignores filler.

Words are little-endian 32-bit complex samples: I in bits 15:0, Q in 31:16.
`MAGIC=F15ACAFE`, `ESC=F15ACAFD`, `START=53544152`, `END=454E4421`.
Inside a frame, a payload word equal to MAGIC or ESC is preceded by ESC.
The sample count and XOR cover original IQ words, excluding escapes. `abort`
clears an unfinished frame so a later trigger can start a new one.
The framing protocol detects truncated/corrupted DMA output but cannot detect
ADC samples dropped before the framer; upstream overflow remains a separate
hardware status condition. Registered AXI input and output words isolate
the FIR-to-cpack data path and keep the input `TREADY` independent of IQ bits.
