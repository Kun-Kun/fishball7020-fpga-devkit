# Capturing IQ with metadata and an integrity check

How to record IQ samples so the file describes itself and says whether samples
were lost, using `tools/sigmf-capture.py`. A bare `iio_readdev` capture has no
sample rate, frequency or gain in it, and returns the byte count you asked for
whether or not the hardware kept up. Read this before recording anything you
intend to keep, analyse or share.

```bash
# run from: the repo root
tools/sigmf-capture.py record out --rate 3e6 --freq 900e6 --seconds 5 \
    --channels both --verify --annotate
```

That writes `out.sigmf-data` (the samples, untouched) and `out.sigmf-meta` (JSON
describing them, including a verdict on whether the capture is intact). MATLAB
reads the same files with `fishball.readSigMF`, no support package needed; see
[matlab.md](matlab.md#no-support-package).

## What SigMF is

**SigMF** (Signal Metadata Format) is a convention: the samples as
`x.sigmf-data`, plus a small JSON "sidecar" `x.sigmf-meta`. Every value in the
sidecar is **read back from the board after configuration**, never copied from
the command line, because the AD9361 quantises gain, `rf_bandwidth` and
`sampling_frequency` to what it supports.

## Full scale is 2047

```jsonc
// excerpt from a .sigmf-meta sidecar
"core:datatype": "ci16_le",
"fishball:full_scale": 2047,
"fishball:scaling_note": "Samples are signed 12-bit sign-extended into int16.
                          Divide by 2047 for full scale, NOT 32768."
```

`ci16_le` (complex, signed 16-bit, little-endian: four bytes per sample, I then
Q) describes the container, so a reader will assume ±32767. The converters are
12-bit, so full scale is **±2047**; the board reports `le:S12/16>>0` from
`iio_attr -i -c cf-ad9361-lpc`. Dividing by 32768 makes every absolute level
**24 dB** low, uniformly; ratios such as SNR and EVM are unaffected.

## Sample-rate limits

One board on gigabit Ethernet, receive only, `TX2A` → 20 dB pad → `RX2A`, `RX1A`
open, both transmitters at the −89.75 dB floor. Each channel is 4 bytes per
sample.

| | Data rate | 1 s of samples took | Phase jumps |
|---|---|---|---|
| 1 channel @ 10 MSPS | 40 MB/s | 1.19 s | 0 (clean) |
| 2 channels @ 10 MSPS | 80 MB/s | 1.69–1.71 s | **3 to 21 (dropping)** |
| 2 channels @ 3 MSPS | 24 MB/s | 1.10–1.29 s | 0 (clean) |

Receive alone sustains about 40 MB/s (the ~31 MB/s in
[modulation-and-throughput.md](modulation-and-throughput.md) is with transmit
running too). Above that the DMA (the FPGA block that moves samples to memory)
overflows, samples are discarded, and the capture still completes; only
`--verify` tells you. `sigmf-capture.py` warns above about 30 MB/s and uses
`-b 1048576` by default (`--buffer`); smaller buffers fail sooner. Find your own
threshold:

```bash
# run from: the repo root
for r in 3e6 5e6 10e6; do
  tools/sigmf-capture.py record /tmp/t --channels both --rate $r --seconds 2 --verify
done
```

With the transmitter muted, a looped channel reads about 13 dB hotter than an
open one (RSSI 110.5 against 123.75 dB below full scale): the cable carries the
transmit chain's residual noise. One board and bench, not a specification.

## `--verify`: does the capture have holes in it?

A dropped chunk leaves a **step in phase**. The check blanks bins within about
±5 kHz of DC, finds the strongest tone, de-rotates by it (multiplies by a complex
exponential at minus its frequency, so the tone stands still), averages the phase
over 1000-sample blocks, and flags any step above 0.5 radian between blocks.

If the air is quiet, inject a tone with the AD9361's built-in self-test (BIST),
inside the chip with no RF:

```bash
# run from: your host — mode 2 injects into RX; nothing transmits
iio_attr -u ip:fishball.local -D ad9361-phy bist_tone "2 375000 12 0"
#   ... capture ...
iio_attr -u ip:fishball.local -D ad9361-phy bist_tone "0 0 0 0"
```

A clean capture records:

```jsonc
// excerpt from a .sigmf-meta sidecar
"fishball:integrity": {
  "checked": true,
  "channel": "RX1",
  "method": "phase continuity of the strongest tone, averaged over 1000-sample blocks",
  "tone_hz": 375000.0,
  "blocks_tested": 6000,
  "phase_jumps": 0,
  "verdict": "continuous"
}
```

A broken one records `"verdict": "DISCONTINUOUS - samples were dropped"`,
`phase_jumps`, `worst_jump_rad` and `jump_at_samples`, and every discontinuity
also becomes a standard SigMF annotation labelled `dropped samples (RX1)`.

There are three verdicts: `continuous`, `DISCONTINUOUS`, and **`inconclusive`**
with a reason, returned when no tone away from DC stands **30 dB** above the noise
floor, or when more than a fifth of the blocks trip (the de-rotation never
locked). Skipping `--verify` records `"checked": false` with a reason. It finds
discontinuities only: a drop of an exact multiple of the tone's period slips
through.

## `--annotate`: what is in the capture

Two passes, written as standard SigMF annotations with absolute frequency edges:
**spectrum** peaks (with a guard band, each with its −20 dB width) and
**clipping** (any sample at or beyond ±2047; a clipped capture contains harmonics
that were never on the air). The spike at 0 Hz offset is labelled
`LO leakage (artefact, not a signal)`: every zero-IF receiver (one that mixes
straight to 0 Hz) leaks its own local oscillator there.

## Both receivers at once

```bash
# run from: the repo root
tools/sigmf-capture.py record out --channels both --rate 3e6 --seconds 5 --verify
```

One file, `core:num_channels: 2`, interleaved **RX1-I, RX1-Q, RX2-I, RX2-Q** per
sample instant (confirmed on hardware). `--split` writes two single-channel
recordings instead.

```
# IIO channel names on the two devices
ad9361-phy      input voltage0 = RX1,        voltage1 = RX2
cf-ad9361-lpc   input voltage0/1 = RX1 I/Q,  voltage2/3 = RX2 I/Q
```

Gain, rate and bandwidth live on `ad9361-phy`; the sample stream is
`cf-ad9361-lpc`. `voltage2` on the phy has no `hardwaregain`, so using it for
RX2's gain fails silently. `RX_LO` is an **output** channel and needs `-o`.

**Coherent, but not calibrated.** Both receivers share one `RX_LO`, so their
phase relationship is stable (0.000° mean, 0.0000° standard deviation across 15
million samples with the BIST tone). BIST is injected digitally, so that shows
only sample alignment. The analogue phase offset through baluns and traces is
real, tens of degrees and frequency-dependent: measure it with a splitter and
matched cables before trusting any angle. The sidecar carries this warning.

## Reading one back

```python
# run from: anywhere, beside the capture
import json, numpy as np

meta = json.load(open("out.sigmf-meta"))
fs   = meta["global"]["core:sample_rate"]
full = meta["global"]["fishball:full_scale"]        # 2047, not 32768
nch  = meta["global"].get("core:num_channels", 1)

v = np.fromfile("out.sigmf-data", dtype="<i2").reshape(-1, 2 * nch)
rx1 = (v[:, 0] + 1j * v[:, 1]) / full
rx2 = (v[:, 2] + 1j * v[:, 3]) / full if nch > 1 else None

print(meta["global"]["fishball:integrity"]["verdict"])
```

`<i2` is numpy's spelling of `ci16_le`: little-endian, signed, two bytes.
