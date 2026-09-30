# Isolating one FM channel in the FPGA

A worked example of putting real DSP into the AD9361 datapath: the board
delivers **one** 200 kHz WBFM (wideband FM broadcast) channel and nothing else,
with every other station removed in the fabric before a single sample crosses
USB. It is an opt-in patch, `firmware/patches/optional/0003-wbfm-channelizer.patch`;
read this page to build it, or as a template for your own FPGA filter.

The default configuration targets **102.1 MHz** (Studio Brussel), but the
station is a runtime control; see [Retuning](#retuning-to-another-station).

Quick start (details in [Building it](#building-it) and [Running it](#running-it)):

```bash
# run from: firmware/
# needs src/ (./scripts/setup.sh) and one prior full ./scripts/build_all.sh
(cd src && git apply ../patches/optional/0003-wbfm-channelizer.patch)
rm -rf src/hdl/projects/pluto/pluto.{xpr,cache,gen,hw,ip_user_files,runs,sim,srcs,sdk}
./scripts/build_all.sh --hdl-only
```

Contents:

- [Why tuning on-channel does not work](#why-tuning-on-channel-does-not-work)
- [The arithmetic](#the-arithmetic) · [The datapath](#the-datapath)
- [Building it](#building-it) · [Running it](#running-it)
- [Retuning](#retuning-to-another-station) · [Designing your own filter](#designing-your-own-filter)

## Why tuning on-channel does not work

The first idea is to tune the radio near the station, then lowpass the
channel. Two things break that.

**1. Tuning on-channel puts the radio's own defects in your audio.** A
zero-IF receiver like the AD9361 (one that mixes the tuned frequency straight
down to 0 Hz) leaks its local oscillator into its own mixer and carries a DC
offset in the baseband ADCs. Both land at exactly 0 Hz, the centre of the
channel if you tuned on-channel. Standard practice is to tune *off*-channel so
the wanted signal sits at some baseband offset and the junk at DC is somewhere
harmless.

**2. But then a real filter cannot select it.** A FIR with real coefficients,
applied separately to I and Q, has a magnitude response that is **symmetric
about DC**. Ask it to pass 1.0–1.2 MHz and it passes −1.2 to −1.0 MHz just as
faithfully: a different station about 2 MHz below the one you want, mixed
straight into your demodulator, with no way to tell them apart afterwards.

Selecting a band that is *not* centred on DC needs complex coefficients, which
costs four real filters instead of two.

**The cheap way out:** move the channel to DC first, then a real lowpass is
exactly the right tool. If the sample rate is chosen so the offset is exactly
**Fs/4**, that move is free.

Multiplying by `exp(-j*pi*n/2)` cycles through `1, -j, -1, +j`. Every
"multiply" is a swap of I and Q plus a sign flip:

```
# the Fs/4 shift, sample by sample
n=0   x  1   ->  ( I,  Q)
n=1   x -j   ->  ( Q, -I)
n=2   x -1   ->  (-I, -Q)
n=3   x +j   ->  (-Q,  I)
```

No multipliers, no NCO (numerically controlled oscillator), no coefficients, no
block RAM. Two registers and a 2-bit counter.

## The arithmetic

Everything follows from two constraints: the offset must equal `Fs/4`, and
`Fs/8` (after the FPGA's ÷8 decimator) should be a whole multiple of 48 kHz so
the audio path needs no resampler.

```
# the two constraints
Fs = 4 x offset                and       Fs / 8 = k x 48000
```

Solving both gives `Fs = 384000 x k`. For an offset near 1 MHz, `k = 11`:

| | |
|---|---|
| Station | 102.1 MHz |
| **AD9361 sample rate** | **4.224 MSPS** (= 384000 × 11) |
| Offset = Fs/4 | 1.056 MHz |
| **RX LO** | **101.044 MHz** (= 102.1 − 1.056) |
| FPGA decimation | ÷8 |
| **Delivered rate** | **528 kSPS**, channel centred at DC |
| Audio decimation | 528000 / 48000 = **11**, exact |

**2.083 MSPS, the AD9361's floor, is too slow for this.** Its Nyquist band is
±1.042 MHz and the channel's upper edge needs 1.2 MHz, so the channel would fold
before any filter saw it. 2.304 MSPS (±1.152 MHz), the rate of the earlier
flowgraph in this repo, has the same problem. The rate has to go *up*, not
down.

### The spur comes back, and the filter is what stops it

Offset tuning moves the LO-leakage spur off the channel, then decimation brings
it back. After the Fs/4 shift the spur sits at −1.056 MHz, and 1.056 MHz is
exactly 2 × 528 kHz, so ÷8 decimation folds it **precisely onto DC**: the
centre of the wanted channel.

Only the FIR's stopband depth at that one frequency prevents that. It is about
−84 dB there, and the worst case anywhere in the stopband is −78.5 dB, so the
spur is well suppressed. `gen_fir_coe.py` probes that exact frequency and
prints it for this reason. If you change the rate plan, re-check it.

## The datapath

```
# receive path with the patch applied
AD9361   LO 101.044 MHz, 4.224 MSPS
   |     wanted channel at +1.056 MHz;  LO-leak + DC offset at 0
   v
axi_ad9361   adc_data_i0 / adc_data_q0
   |
   v
rx_ddc  (ad_fs4_ddc.v)          <- NEW: x exp(-j*pi*n/2), 0 DSPs, 0 BRAM
   |     wanted channel now at DC;  spur pushed to -1.056 MHz
   v
rx_fir_decimator                <- EXISTING block, new coefficients
   |     321-tap lowpass, Fpass 100 kHz, Fstop 175 kHz, then /8
   v
cpack -> adc_dma -> USB         528 kSPS, the channel and nothing else
```

The TX path is unchanged. **Channel 1 is not a usable second receiver while
this is running.** This patch pins the decimator to channel 0 only (see the
cost row below), and `cpack` clocks every channel on channel 0's write strobe
(`rx_fir_decimator/valid_out_0`), so with decimation engaged channel 1 gets a
naive 1-in-8 downsample with no anti-aliasing. Its usable band shrinks to
±264 kHz, and everything the analog filter lets through (roughly ±2 MHz) folds
on top of that. This is upstream's wiring; see
[both-receive-channels.md](both-receive-channels.md).

| File | What it does |
|---|---|
| `firmware/src/hdl/projects/pluto/ad_fs4_ddc.v` | the Fs/4 shifter |
| `firmware/src/hdl/projects/pluto/system_bd.tcl` | wires it in, repoints the coefficients |
| `firmware/patches/optional/0003-wbfm-channelizer.patch` | both of the above; **opt-in**, `setup.sh` does not apply it |
| `firmware/scripts/gen_fir_coe.py` | designs and verifies the coefficients (no MATLAB needed) |
| `firmware/scripts/coefile_wbfm_102100.coe` | its output, 321 taps |
| `docs/grc/fishball_wbfm_rx.grc` | the GNU Radio receiver, with no software channel filter left in it |

### Filter performance

321 taps, Kaiser window, quantised to 16-bit integers summing to 2^17 (the
stock DC-gain convention):

| | |
|---|---|
| Passband ripple, 0–100 kHz | 0.0019 dB |
| Stopband edge, 175 kHz | −113 dB |
| Adjacent channel carrier, 200 kHz | −78.7 dB |
| Folded LO spur, 1.056 MHz | far below the floor |
| **Worst case anywhere ≥ 175 kHz** | **−78.5 dB** |
| Cost | **96 of 220 DSP48s** (72 before the change, so +24). Both figures are against the channel-0-only decimator, which is what this example builds: it pins `rx_filt_chan` to 2 regardless of patch `0021`, because its coefficients are a 200 kHz FM channel and putting RX2 through them would give you the same station twice rather than a second receiver |

Do not raise the tap count hoping for more: past ~321 taps this filter is
limited by **16-bit coefficient quantization**, not by taps, and more taps make
it slightly worse. `gen_fir_coe.py` documents the figures.

Taps are cheap here because the filter decimates: the IP gets eight input
sample periods' worth of clock cycles to compute each output, so it folds
321 taps onto a handful of multipliers.

Utilisation and timing from a full synthesis and implementation run:

| | Before | After |
|---|---|---|
| DSP48s | 72 | **96** / 220 (43.6%) |
| Slice LUTs | 11 893 | 12 664 / 53 200 (23.8%) |
| Slice registers | 20 851 | 22 300 / 106 400 (21.0%) |
| Worst negative slack | — | **+0.292 ns**, 0 failing endpoints of 55 269 |

The Fs/4 shifter costs no DSPs; the whole +24 is the channel filter going from
129 to 321 taps.

## Building it

The coefficients and the block-design change both need the FIR IP regenerated,
and `build_hdl.tcl` reuses an existing `pluto.xpr` rather than re-running
`system_bd.tcl`. **Delete the project first**, or the build produces the old
filter without any error.

```bash
# run from: firmware/
./scripts/setup.sh          # if src/ does not exist yet
# --hdl-only reuses the kernel, U-Boot and rootfs from a previous FULL build
# and refuses to run without one - run a plain ./scripts/build_all.sh first.

# This example is NOT applied by default - it narrows RX channel 0 to one
# broadcast channel, which is not what a general-purpose build should do.
(cd src && git apply ../patches/optional/0003-wbfm-channelizer.patch)
rm -rf src/hdl/projects/pluto/pluto.{xpr,cache,gen,hw,ip_user_files,runs,sim,srcs,sdk}
./scripts/build_all.sh --hdl-only
```

`--hdl-only` reuses the existing kernel, U-Boot and rootfs, which are
unaffected: about 20 minutes instead of 70. Then flash `output/` as usual.

Check before flashing:

```bash
# run from: firmware/
grep -A6 "^4. DSP" src/hdl/projects/pluto/utilization.rpt   # expect 96 / 220
grep -A3 "Design Timing Summary" src/hdl/projects/pluto/timing.rpt
```

## Running it

Two rates must be set, and **the second one engages the filter**: it drives
`GP_CONTROL` bit 0, which selects the filtered path through the bypass mux in
the bitstream. Without it the samples arrive unfiltered.

```bash
# run on the BOARD
iio_attr -o -c ad9361-phy altvoltage0 frequency 101044000     # RX LO
iio_attr -i -c ad9361-phy voltage0 sampling_frequency 4224000 # converter rate
iio_attr -i -c ad9361-phy voltage0 rf_bandwidth 4000000       # analog LPF
iio_attr -i -c cf-ad9361-lpc voltage0 sampling_frequency 528000   # <- engages the FIR
```

Read the converter rate back. If the AD9361 lands on something other than
4224000, the channel is no longer at exactly Fs/4 and sits off-centre.

**Check the shifter is in the bitstream.** With `rx_ddc` present, the
LO-leakage spur (at exactly 0 Hz on any zero-IF receiver, and not movable from
software) appears at −1.056 MHz instead. If it is still at DC, the bitstream
you flashed does not contain the change.

**Check the filter with an A/B.** Set `cf-ad9361-lpc voltage0
sampling_frequency` back to 4224000 to bypass the filter, and a neighbouring
station reappears in the spectrum. Set it to 528000 again and it drops into the
noise floor. On hardware, with the rate plan above and a 65 536-point
transform:

| | Filter bypassed | Filter engaged |
|---|---|---|
| Out-of-band signal at −724 kHz | −66.5 dBFS, 37.8 dB over the floor | gone |
| Capture RMS | −49.2 dBFS | −78.6 dBFS |
| Peak sample | 23 LSB | 1 LSB |

29 dB of total captured energy removed, and nothing left standing outside the
passband. The noise floor also drops 22.6 dB, because decimation folds eight
times less bandwidth into the delivered stream.

**The GNU Radio flowgraph is untested on hardware.**
`docs/grc/fishball_wbfm_rx.grc` is written to do all of the above, and sets
both rates from a Python snippet that runs after initialisation (gr-iio
programs the AD9361 on its own and does not know about the FPGA decimator). The
FPGA filter has been run on the board; the GNU Radio side has not. Treat the
flowgraph as a starting point, and if you run it, say so in an issue or PR so
this caveat can be removed.

## Retuning to another station

The FPGA filter sits at DC, so it follows the LO: any FM station works at
runtime with no rebuild, as long as the sample rate stays 4.224 MSPS:

```
# LO for a given station, in Hz
LO = station - 1056000
```

The `Station (Hz)` slider in the flowgraph does exactly this.

Changing the *sample rate* needs a rebuild, because the offset must stay at
Fs/4 and the coefficients are designed for one Fs. For a different rate, pick
`Fs = 384000 x k` so the audio decimation stays a whole number, set `FS_IN` in
`gen_fir_coe.py`, regenerate, and rebuild.

## Designing your own filter

```bash
# run from: firmware/scripts
python3 gen_fir_coe.py
```

Standard library only: no MATLAB, no numpy. It prints the response at the four
frequencies that decide whether the design works (passband edge, stopband
edge, adjacent-channel carrier, and the folded LO spur), checks passband ripple
and worst-case stopband, and **exits non-zero rather than writing a file that
fails those checks**. Edit the configuration block at the top to retarget it.

`gen_fir_coe.m` is the older MATLAB equivalent. It designs an equiripple
filter, which reaches a given stopband with roughly 30% fewer taps, but needs
the Signal Processing Toolbox. Either is fine here; taps are cheap in a
decimating filter.

## `rx_ddc` is always in the path

`rx_ddc` sits *ahead* of the bypass mux. With FPGA decimation switched off you
get a 4.224 MSPS stream that is frequency-shifted but unfiltered, not a raw
one. That is harmless, and useful for the A/B test above, but expect it when
you read an undecimated capture from this build.
