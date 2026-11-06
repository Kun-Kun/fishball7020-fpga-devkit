# AXI ramp gate

`axis_gate` forwards 32-bit AXI4-Stream samples after a rising `start` edge
and stops after a rising `stop` edge. `DATA_WIDTH` is configurable. It accepts
and discards input while closed, so the ADC stream keeps running. One elastic
output register preserves AXI handshakes under backpressure; a sample accepted
while the gate was open may leave the register after `stop`.

`start` is synchronized to `clk`. `stop` has an asynchronous-set pulse catcher
before synchronization so a short ADF4159 MUXOUT ramp-complete pulse is not
missed. `active` reports the open gate. `done` latches a completed interval and
clears on the next start or reset. Reset is synchronous and active high for the
stream and status outputs. `abort` closes the gate without reporting completion.
Keep `stop` low during reset.

`bypass=1` forwards samples without changing the active/done state. The board
drives it from an internal EMIO GPIO bit so CW measurements and legacy
continuous captures can use the existing RX DMA path.

The Pluto block design places one gate on RX1 and another on the RX2 beat
stream, before their FIR inputs. Both see TXDATA as `start` and MUXOUT as
`stop`. With both closed, cpack and the RX DMA produce no samples; their
upstream streams are drained without backpressure.
