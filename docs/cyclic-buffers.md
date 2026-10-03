# Cyclic buffers and triggers

A **cyclic buffer** is a transmit waveform the board plays from its own memory,
over and over, until you stop it. Your PC sends it once; after that the FPGA's
DMA engine (the hardware that moves samples between memory and the radio)
repeats it with no further help from the host, at any sample rate up to
61.44 MS/s and on both transmitters.

Use one when the signal repeats: a test tone, a calibration pattern, a radar
chirp, a beacon. It is also the only way to transmit fast: a *streaming*
transmit, where the PC keeps sending new samples, breaks down above about
5 MS/s ([throughput](modulation-and-throughput.md)). A cyclic transmit has no
such limit, because nothing crosses the network once it runs.

This page covers starting and stopping one, the board's limits on them, and
how to trigger other equipment from one. The short version on triggering: the
board can send a trigger **out**, locked to the exact sample. It cannot take a
trigger **in** with the FPGA design it ships.

> [!CAUTION]
> **Read [transmitter safety](transmitter-safety.md) first.** The board puts out
> about +19 dBm and its receivers survive only +2.5 dBm: never loop TX into RX
> without at least 20 dB of attenuation, and transmit only where you are
> allowed to. Three rules apply to every example below:
>
> - **Set the TX attenuation after the buffer starts, and read it back.**
>   Starting a buffer restores a cached attenuation, which can be louder than
>   what you set before it.
> - **Mute before you stop the buffer, never after.** Stopping caches whatever
>   attenuation it finds, for the next buffer to restore.
> - **The devkit's own transmitting tools** refuse to raise the output until you
>   run `./devkit tx-guard affirm 0` (or `1`) on your PC. Your own code is not
>   checked, so the rules are yours to follow.

## From Python

[pyadi-iio](https://github.com/analogdevicesinc/pyadi-iio), Analog Devices'
Python package, plays a cyclic buffer with one setting, `tx_cyclic_buffer`:

```python
# run from: your PC.  pip install pyadi-iio numpy
import adi, numpy as np

sdr = adi.ad9361("ip:192.168.2.1")      # or ip:fishball.local over Ethernet
sdr.tx_enabled_channels = [0]           # TX1
sdr.sample_rate = 30_720_000            # shared by RX and TX on this chip
sdr.tx_lo = 433_920_000                 # a licence-free band
sdr.tx_cyclic_buffer = True             # play the buffer forever

# 1 MHz tone. 30.72 MS/s / 1 MHz is not a whole number, so pick N to hold a
# whole number of cycles: 3840 samples = exactly 125 cycles. Then the end of
# the buffer joins its start with no jump.
N  = 3840
n  = np.arange(N)
iq = 0.5 * 2**15 * np.exp(2j * np.pi * 1e6 * n / sdr.sample_rate)

sdr.tx(iq)                              # starts it; returns at once
for _ in range(10):                     # AFTER the start: set, then read back
    sdr.tx_hardwaregain_chan0 = -40     # dB; -89.75 is muted, 0 is maximum
    if abs(sdr.tx_hardwaregain_chan0 + 40) < 0.3:
        break
else:
    raise RuntimeError("TX attenuation did not apply")

input("transmitting - press Enter to stop")
sdr.tx_hardwaregain_chan0 = -89.75      # mute FIRST...
assert sdr.tx_hardwaregain_chan0 <= -89.0
sdr.tx_destroy_buffer()                 # ...then stop
```

Samples are full-scale at ±32767: the 12-bit DAC uses the top 12 bits of each
16-bit value.

**Both transmitters at once** start together and stay sample-aligned, because
they come from one buffer:

```python
# run from: your PC, continuing from the example above
sdr.tx_enabled_channels = [0, 1]        # TX1 and TX2
sdr.tx([iq_tx1, iq_tx2])                # two arrays of the same length
# then set and read back tx_hardwaregain_chan0 AND tx_hardwaregain_chan1
```

**To change the waveform**, mute, `tx_destroy_buffer()`, then `tx()` the new one
and set the attenuation again. The output stops for the moment in between: a
running cyclic buffer cannot be swapped seamlessly.

## From the command line

`iio_writedev` (from the `libiio-utils` package, on your PC or on the board)
plays a file cyclically with `-c`. The file is raw 16-bit samples, I then Q,
for each channel in turn, and `-b` must be its length in samples, so the
whole file is one buffer:

```bash
# run from: the board (or your PC, with -u ip:192.168.2.1 instead of local:)
# tone.iq: 16384 samples of TX1 I,Q as int16 = 65536 bytes
iio_writedev -u local: -c -b 16384 cf-ad9361-dds-core-lpc voltage0 voltage1 < tone.iq &
sleep 0.5
iio_attr -u local: -o -c ad9361-phy voltage0 hardwaregain -40     # after the start
iio_attr -u local: -o -c ad9361-phy voltage0 hardwaregain         # and read it back
# ... and to stop: mute first, then end the writer
iio_attr -u local: -o -c ad9361-phy voltage0 hardwaregain -89.75
kill %1
```

`iio_writedev` keeps running while the buffer plays, and ending it stops the
buffer. `voltage0 voltage1` is TX1; add `voltage2 voltage3` for TX2 as well,
with the file interleaving I1, Q1, I2, Q2.

## The board's limits on cyclic buffers

| Limit | What it does | How to change it |
|---|---|---|
| **60 s bound** (modern firmware) | mutes a cyclic transmit 60 s after it started, so a forgotten one does not run for days | `fw_setenv tx_cyclic_bound 0` on the board turns it off from the next boot; `<ms>` sets another length. This boot only: `echo 0 > /sys/bus/iio/devices/iio:device2/tx_cyclic_timeout_ms` |
| **First-block time** (v2.3 and later) | a large buffer gets 250 ms plus 1 ms per kB to arrive before the starve watchdog may mute it, at most 10 s: a 4.46 MB buffer gets 4.7 s | `fw_setenv tx_starve_ms <ms>` changes the watchdog itself (`0` = off) |
| **Largest buffer** | 64 MB per DMA block by default | `fw_setenv iio_max_block_size <bytes>` |
| **Length** | the DMA rounds some lengths: a 16385-sample buffer does not play as 16385 | use a multiple of 16 samples |

Details and the reasoning behind each: [transmitter safety](transmitter-safety.md#cyclic-transmits-and-the-60-s-bound).

Two more things to know:

- **Make the buffer hold whole periods** of every signal in it, as the 3840 in
  the Python example does. Otherwise each repeat jumps in phase, which spreads
  spurs across the spectrum.
- **Never engage the FPGA's ÷8 transmit interpolator** (setting the DDS core's
  rate to an eighth of the chip's). On this board TX1 then emits nothing at all.

## Triggering

### Out: a pulse locked to the buffer

The board's four **sample-locked GPIO pins** (JP5 pins 7, 9, 11 and 13) carry
the low 4 bits of every transmit sample, bits the 12-bit DAC discards. Set a
bit in the sample where you want a trigger, and that pin goes high for exactly
that sample, every time the buffer repeats. A scope, a logic analyser or an
external switch can trigger on it:

```python
# run from: your PC, before sdr.tx() in the Python example above
i16 = iq.real.astype(np.int16)
q16 = iq.imag.astype(np.int16)
marker = np.zeros(N, dtype=np.int16)
marker[0] = 0b0100                       # bit 2 = JP5 pin 11, high on sample 0 only
i16 = (i16 & ~np.int16(0x000F)) | marker # LAST step: clear the low 4 bits, put the marker in
iq = i16.astype(np.complex128) + 1j * q16.astype(np.complex128)
# and turn the pins on (an attribute pyadi-iio does not expose):
import iio
iio.Context("ip:192.168.2.1").find_device("cf-ad9361-dds-core-lpc").attrs["tx_sample_gpio_en"].value = "1"
```

- **It is exact to the sample.** Measured with a logic analyser: every marker
  arrives, in order, with both transmitters running a 4.46 MB cyclic buffer at
  40 and 60 MS/s, from the very first block on
  ([measured results](tx-gpio-bitmap.md#measured-results)).
- **The pin leads the RF** by a constant delay of roughly a microsecond, the
  time the samples take through the AD9361. That delay has not been measured;
  calibrate it once in your setup if it matters.
- **OR the marker in last**, after any scaling or conversion, or those steps
  overwrite it.

Everything else about the pins (levels, all four bits, clocks and frame
signals) is on [sample-locked GPIO](tx-gpio-bitmap.md).

### In: not in the FPGA design this board ships

The board cannot wait for an external trigger before it starts a buffer. The
radio's FPGA core has an input for one (`dac_sync_in`), but the block design
leaves it unconnected, and the core reports that it has no external sync. The
`sync_start_enable` attribute on both the transmit and receive cores therefore
offers only `arm`, which on this board just restarts the transmit core's
internal timing. It waits for nothing.

A buffer starts when software enables it, after a delay (software, and the
network if you drive it from a PC) that is not fixed and has not been measured
here. Two ways around it:

- **Measure the offset instead of triggering.** Both transmitters and both
  receivers share one clock. Once a cyclic transmit and a receive capture are
  both running, the offset between them stays constant until either restarts:
  find it once by correlating the received signal (through a loop with at least
  20 dB of attenuation) against the transmitted one.
- **Wire a trigger in.** Connecting `dac_sync_in` to a free pin in the block
  design and rebuilding the bitstream would add one. That is an FPGA change,
  untested here; [the stock block design](block-design.md) is the place to
  start.
