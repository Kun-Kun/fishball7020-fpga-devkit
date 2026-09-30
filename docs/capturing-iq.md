# Capturing IQ with metadata and an integrity check

How to record IQ samples off this board so the file describes itself and says
whether any samples were lost, using `tools/sigmf-capture.py`. Read it before
recording anything you intend to keep, analyse later or share.

A raw capture from `iio_readdev` has two problems. **It does not describe
itself:** bare samples, no header, no sample rate, centre frequency, gain or
date. **It does not say it is broken:** `iio_readdev` returns the byte count you
asked for whether or not the hardware kept up, so a capture that overflowed
looks exactly like one that did not.

```bash
# run from: the repo root
tools/sigmf-capture.py record out --rate 3e6 --freq 900e6 --seconds 5 \
    --channels both --verify --annotate
```

That writes `out.sigmf-data` (the samples, untouched) and `out.sigmf-meta`
(JSON describing them), and the metadata file carries its own verdict on
whether the capture is intact.

> **Reading these in MATLAB.** `fishball.readSigMF` reads exactly this
> format, `fishball:full_scale` included, and needs no support package; see
> [matlab.md](matlab.md#no-support-package).

## What SigMF is

**SigMF** (Signal Metadata Format) is a convention, not a library. Rename the
capture `x.sigmf-data`, write a small JSON file `x.sigmf-meta` beside it (the
"sidecar"), and every tool that read the bare file still reads it, while the
file now explains itself.

Everything in the sidecar is **read back from the board after configuration**,
never copied from the command line. The AD9361 quantises gain to its own table,
`rf_bandwidth` snaps to what the filter design supports, and
`sampling_frequency` lands on what the clock tree can produce. A value you
wrote is an intention; a value read back is what the board is doing.

## The one field that is not optional

```jsonc
// excerpt from a .sigmf-meta sidecar
"core:datatype": "ci16_le",
"fishball:full_scale": 2047,
"fishball:scaling_note": "Samples are signed 12-bit sign-extended into int16.
                          Divide by 2047 for full scale, NOT 32768."
```

`ci16_le` means *complex, signed integer, 16 bits, little-endian*: four bytes
per sample, I then Q. It describes the **container** and has no way to say what
counts as full scale, so a reader will reasonably assume ±32767.

On this board full scale is **±2047**, because the converters are 12-bit,
sign-extended into an int16. The board reports it: `iio_attr -i -c
cf-ad9361-lpc` gives the format as `le:S12/16>>0`.

Divide by 32768 instead and every absolute level is **24 dB** too low,
uniformly, so nothing looks wrong. Spectra keep their shape and every SNR and
EVM figure is unchanged, because those are ratios and the error cancels. Only
absolute levels move, and they move together.

## Sample-rate limits

Conditions: one board on gigabit Ethernet, receive only, `TX2A` looped to
`RX2A` through a 20 dB pad, `RX1A` open, both transmitters at the −89.75 dB
floor. Each channel is 4 bytes per sample, so two channels is 8.

| | Data rate | 1 s of samples took | Phase jumps |
|---|---|---|---|
| 1 channel @ 10 MSPS | 40 MB/s | 1.19 s | 0 (clean) |
| 2 channels @ 10 MSPS | 80 MB/s | 1.69–1.71 s | **3 to 21 (dropping)** |
| 2 channels @ 3 MSPS | 24 MB/s | 1.10–1.29 s | 0 (clean) |

The jump count in the middle row varies run to run, because how badly the DMA
(the FPGA block that moves samples into memory) overflows depends on what else
the host and the network are doing. Neither the file nor one good run tells you
whether a capture is intact; `--verify` does.

The ~31 MB/s plateau in
[`modulation-and-throughput.md`](modulation-and-throughput.md) is a
**bidirectional** figure: transmit feeding the DMA while receive drained it.
Receive alone has the link to itself and sustains closer to 40 MB/s. Above that
the DMA overflows, samples are discarded, and the capture still completes.
`sigmf-capture.py` warns when a requested rate exceeds about 30 MB/s.

The buffer size matters: `sigmf-capture.py` uses `-b 1048576` by default
(`--buffer` changes it). Smaller buffers fall over sooner.

To find the drop threshold on your own setup, walk the rate up:

```bash
# run from: the repo root
for r in 3e6 5e6 10e6; do
  tools/sigmf-capture.py record /tmp/t --channels both --rate $r --seconds 2 --verify
done
```

**Cabling shows up in the levels.** With the transmitter muted, the looped
channel reads about **13 dB hotter** than the open one (RSSI 110.5 against
123.75 dB below full scale). A loopback cable carries the transmit chain's
residual noise into the receiver even when nothing is being sent; an open port
sees only the room. Allow for this when comparing your numbers. All of this
section describes one board and one bench, not a specification.

## `--verify`: does the capture have holes in it?

### How it works

A dropped chunk leaves no marker in the file. It does leave a **step in phase**.

1. Blank the bins within about ±5 kHz of DC, then find the strongest tone.
2. **De-rotate** by it: multiply every sample by a complex exponential at minus
   that frequency, which stands the tone still.
3. What remains should be a constant phase. Average it over 1000-sample blocks.
4. Any step bigger than 0.5 radian between adjacent blocks is samples that are
   not there.

If the air is quiet, inject a tone inside the chip. The AD9361's built-in self
test (BIST) generates one on the receive path with no RF involved:

```bash
# run on your HOST — mode 2 injects into RX; nothing transmits
iio_attr -u ip:fishball.local -D ad9361-phy bist_tone "2 375000 12 0"
#   ... capture ...
iio_attr -u ip:fishball.local -D ad9361-phy bist_tone "0 0 0 0"
```

### What it writes

A clean capture:

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

A broken one records where, and **every discontinuity also becomes a SigMF
annotation**, so a reader who ignores the private `fishball:` namespace still
sees it in a standard field:

```jsonc
// excerpt: the integrity block of a broken capture
"verdict": "DISCONTINUOUS - samples were dropped",
"phase_jumps": 21,
"worst_jump_rad": 2.7395,
"jump_at_samples": [8388000, 8389000, 9437000, ...]
```

```jsonc
// excerpt: one of the matching annotations
{"core:sample_start": 8388000, "core:sample_count": 1,
 "core:label": "dropped samples (RX1)",
 "core:comment": "phase discontinuity: the stream is not continuous across this point"}
```

### Three verdicts, not two

`continuous`, `DISCONTINUOUS`, and **`inconclusive`**, with a reason. The
detector returns `inconclusive` rather than a false verdict in two cases:

- **No dominant tone.** The strongest tone away from DC must stand **30 dB**
  above the noise floor. On a quiet capture with no tone, the strongest bin is
  the receiver's own LO leak at 0 Hz; de-rotating by ~0 Hz does nothing, and
  the test then measures the phase of pure noise (2968 "jumps" out of 3000
  blocks). Blanking the bins around DC and requiring 30 dB prevents that.
- **Too many blocks flagged.** Real drops are occasional. If more than a fifth
  of the blocks trip, the de-rotation never locked, and the tone is not
  coherent enough to test against.

The same three rules apply if you write a similar detector.

Two further limits: **absence of a check is recorded**, so skipping `--verify`
leaves `"checked": false` with a reason rather than an empty field that reads
as a pass; and it detects **discontinuities**, not every possible corruption. A
drop of an exact multiple of the tone's period slips through.

## `--annotate`: what is in the capture

Two passes, both cheap, both written as standard SigMF annotations with
absolute frequency edges.

**Spectrum.** Periodograms averaged from segments spread across the file, then
peak-picked: peaks with a guard band, not everything above a threshold, because
a strong tone's window skirts sit well above any sensible floor and would be
reported as one enormously wide signal. Each peak gets its −20 dB width.

**Clipping.** Any sample at or beyond ±2047. A clipped capture contains
harmonics that were never on the air.

The spike at 0 Hz offset is labelled as an **artefact, not a signal**:

```jsonc
// excerpt: the LO-leakage annotation
{"core:label": "LO leakage (artefact, not a signal)",
 "core:comment": "Zero-IF receivers leak their own local oscillator to 0 Hz.
                  This is the receiver, not the air."}
```

Every zero-IF receiver (one that mixes straight down to 0 Hz) has this spike.
It is easy to mistake for a carrier.

## Both receivers at once

```bash
# run from: the repo root
tools/sigmf-capture.py record out --channels both --rate 3e6 --seconds 5 --verify
```

One file, `core:num_channels: 2`, interleaved **RX1-I, RX1-Q, RX2-I, RX2-Q** per
sample instant. `--split` writes two independent single-channel recordings
instead, for tools that do not handle multi-channel SigMF.

The order is confirmed on hardware: with RX1 at 10 dB of gain and RX2 at 73 dB,
words 0 and 1 are exactly **32.4 dB** quieter than words 2 and 3.

> ### Two devices, two different channel numberings
>
> ```
> # IIO channel names on the two devices
> ad9361-phy      input voltage0 = RX1,        voltage1 = RX2
> cf-ad9361-lpc   input voltage0/1 = RX1 I/Q,  voltage2/3 = RX2 I/Q
> ```
>
> Gain, rate and bandwidth live on the first; the sample stream is the second.
> Reaching for `voltage2` to set RX2's gain fails silently: that channel exists
> on the phy but has no `hardwaregain`. `RX_LO` is an **output** channel, so it
> needs `-o`; reading it with `-i` returns nothing and leaves a null frequency
> in the sidecar.

### Coherent, but not calibrated

Both receivers share one `RX_LO`, so their phase relationship is stable; that
is what makes direction finding possible on this board. With the BIST tone, the
inter-channel phase holds **0.000° mean with 0.0000° standard deviation across
15 million samples**.

BIST injects its tone *digitally* into both chains, so this shows only that the
two streams are **sample-aligned in the buffer**. It says nothing about the
analogue phase offset through the baluns and traces, which is real, tens of
degrees, and different at every frequency.

Measure that offset with a splitter and matched cables before trusting any
angle. The sidecar carries this warning in a field of its own.

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

`<i2` is numpy's spelling of `ci16_le`: little-endian, signed integer, two
bytes.
