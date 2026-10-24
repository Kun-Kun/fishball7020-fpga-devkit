# tx_fir_interpolator

Two-channel complex 8x TX interpolator for Pluto. Each stream is 32 bits wide
with `TDATA[15:0]` carrying I and `TDATA[31:16]` carrying Q. Each component
uses a separate FIR Compiler instance with the same `coefile_int.coe` taps.

`active=1` selects the FIR output; `active=0` selects a direct AXI4-Stream
bypass. The I and Q paths share input and output handshakes so a complex
sample stays paired. The block design clocks it from `axi_ad9361/l_clk` and
connects its outputs to `axis_iq_ch0/1`. `up_dac_gpio_out[2]` selects those
adapters as the DAC source; zero leaves the legacy DMA/upack source selected.

Run `make xilinx` in this directory through the firmware Vivado container to
package the IP. `./devkit setup --target factory` overlays this source into
`firmware/src/hdl/library/`.
