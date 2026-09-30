# 01 — Dynamic range, and how to lose it

A spectrum, a waterfall, and a live number for the dynamic range this
configuration delivers. *Dynamic range* here means peak minus noise floor, in
dB, on the trace you are looking at: the distance between the strongest thing on
screen and the level below which you could not see anything at all.

Receive only. Nothing here transmits. You need an antenna on RX1.

```bash
# run from: the repo root
gnuradio-companion examples/01-dynamic-range/dynamic_range.grc
```

Every control is wired to that number, so you can break the measurement on
purpose and watch it move. Most things that ruin a spectrum ruin it silently:
the picture still looks like a spectrum.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/img/examples-01-dark.svg">
  <img src="../../docs/img/examples-01-light.svg" alt="Two panels. Left: one capture of real air at 2437 MHz processed three times, once per window; the three traces nearly coincide because nothing loud is present, and the receiver's own LO leak stands up as a single spike 1.25 MHz below centre where offset tuning puts it. Right: the same three windows asked to measure a tone whose true level is -60 dBFS sitting 40 bins from a full-scale carrier - rectangular reports -41.4 dBFS, an error of +18.6 dB, while Hann and Blackman-Harris report -61.4 and -60.8." width="100%">
</picture>

## What you should see

The flowgraph runs at 5 MS/s with no overflows. A single `O` (overflow: the
host fell behind and samples were lost) at startup, while the first buffer
fills, is normal. On a quiet band the trace is a flat floor with the receiver's
own LO leak standing up as one spike beside the centre (see *LO offset* below).

## Do this first

Find any strong carrier. A Wi-Fi access point at 2437 MHz will do, and that is
the default. Then change **FFT window** from Blackman-Harris to Rectangular and
back.

A *window* is the taper applied to each block of samples before the FFT.
Without one, a signal that does not fit a whole number of cycles in the block
smears across the whole spectrum. That one dropdown is worth up to **78 dB**. On
a synthetic two-tone test in [`../test_blocks.py`](../test_blocks.py), the
leakage each window leaves 40 bins from a full-scale carrier is:

| window | sidelobes | leakage 40 bins from a full-scale carrier |
|---|---|---|
| rectangular | −13 dB | **−42 dBFS** |
| hann | −31 dB | −106 dBFS |
| blackman-harris | −92 dB | **−120 dBFS** |

And asked to measure a tone whose true level is −60 dBFS, sitting 40 bins from
that carrier:

| window | reads | error |
|---|---|---|
| rectangular | −41.4 dBFS | **+18.6 dB** |
| hann | −61.4 dBFS | −1.4 dB |
| blackman-harris | −60.8 dBFS | −0.8 dB |

A rectangular window does not merely blur the weak tone. It *replaces* it with
the skirt of its loud neighbour and reports that instead. The cost of
Blackman-Harris is about two bins of extra width. That is the whole trade.

One case makes the rectangular window look perfect, and it makes bad tests look
good: a tone sitting *exactly* on a bin centre leaks nothing, and every other
bin is mathematically zero. Real signals are never exactly on a bin centre,
which is why the test above puts both tones half a bin off.

## Then try these

**Set LO offset to 0.** The spike that appears in the middle of the span is the
receiver looking at itself: the local oscillator (LO) leaking into its own
mixer. At any other setting the radio is tuned *beside* what you asked for and
the result is shifted back digitally, so the x-axis still reads true frequency
and the leak lands off to one side. This is *offset tuning*, and almost every
measurement in this repository uses it. The control is a *fraction of the span*
rather than a number of hertz, so it stays sensible when you change the sample
rate.

**Switch Gain mode to slow_attack.** The automatic gain control (AGC) now
changes the receiver's reference level while you are reading levels off it. The
dynamic-range number stays plausible and the vertical axis stops meaning
anything. AGC is right for listening and wrong for measuring; every measurement
tool in this repository uses manual gain for this reason.

**Raise the Noise floor percentile** through a band that is half occupied. The
reported floor climbs into the signals, because a percentile cannot tell noise
from traffic. "Noise floor" is a definition you choose, not a property of the
air. 10% suits a quiet band and is optimistic for a busy one.

**Turn Averaging down to 1.** The trace gets noisy and the peak gets *higher*:
a single frame's noise has taller spikes than an average does. The averaging
here happens in the power domain, which is the only correct way. Averaging
decibels computes a geometric mean of powers and biases every noisy bin low.

**Push Sample rate to 61.44 MS/s.** The span gets twelve times wider, every bin
gets about 11 dB noisier, and the stream needs 245 MB/s, which no Ethernet link
carries. Raise `buf` first and re-run (see below).

## The controls

| control | live? | what it does |
|---|---|---|
| Sample rate | yes | 2.56 to 61.44 MS/s. Lower is better for dynamic range. |
| Centre frequency | yes | 70 MHz to 6 GHz. |
| LO offset | yes | Fraction of the span; moves the LO leak off your signal. |
| Gain mode | yes | manual, slow_attack, fast_attack. |
| RX1 gain | yes | 0–71 dB; above 4 GHz the ceiling is 62 (see below). |
| FFT window | yes | The one this example is about. |
| Averaging | yes | Frames in the power-domain average. |
| Noise floor percentile | yes | What counts as "noise". |
| Max hold | yes | Unticking it is also the reset. |
| Display rate | yes | FFTs per second; the rest are dropped on purpose (see below). |
| `nfft` | **no** | FFT size. See below. |
| `buf` | **no** | libiio buffer, in samples. |

## Pitfalls

- **The gain slider goes to 71; above 4 GHz the maximum is 62.** The AD9361's
  gain table depends on the band. gr-iio only *logs* a refusal from the driver,
  so a value past the end of the table leaves the gain where it was and nothing
  on screen says so. If a level looks stuck, check the gain took:
  `./devkit status`.
- **FFT size is not a runtime control.** It is the width of a vector port, and
  GNU Radio fixes port widths when the flowgraph is built. Edit the `nfft`
  variable and re-run.
- **The buffer size is a trade, not a setting.** `buf` defaults to 262144
  samples (1 MB, about 52 ms at the default rate), which keeps the controls
  responsive. A bigger buffer is worth about 3× the throughput over a network
  ([modulation-and-throughput.md](../../docs/modulation-and-throughput.md)),
  and you need 1048576 or more before selecting a high sample rate. It is fixed
  when the flowgraph starts, so changing it needs a re-run.

## Levels are dBFS

Decibels relative to the converter's full scale, not dBm. A full-scale tone
reads 0.000 dBFS through every window here. [`../test_blocks.py`](../test_blocks.py)
asserts that, along with each window's scalloping loss (3.92 / 1.42 / 0.83 dB):
a window whose own gain is not divided back out puts every level wrong by tens
of decibels, differently per window.

Nothing in this repository is calibrated to absolute power. A dBFS figure says
nothing about what is at the antenna until you add a calibration.

## What is inside

The transform is not GNU Radio's stock frequency sink. `qtgui_freq_sink_x` takes
its window as a constructor argument and has no callback to change it, so the
window could not change while you watch. The transform happens instead in an
embedded Python block, [`../lib/spectrum_engine.py`](../lib/spectrum_engine.py),
which gives three things:

- the window changes while the flowgraph runs;
- averaging happens in the power domain;
- the dynamic-range number is computed from the trace on screen, so the picture
  and the number cannot disagree. Max-hold is display-only. Scoring a max-hold
  trace against a floor taken from an *averaged* trace overstates dynamic range
  by about 13 dB, because the two traces have different floors.

A keep-one-in-n block drops the frames the engine does not need, down to a dozen
a second. A Python FFT cannot keep up with 1200 frames a second, and a block
that falls behind applies backpressure all the way to the radio, which turns
into dropped buffers you did not choose. Dropping frames on purpose is cheaper
and visible.

## Checking it without a radio

```bash
# run from: the repo root
python3 examples/test_blocks.py
```

This asserts the DSP claims on this page (window leakage, scalloping loss,
power-domain averaging) with no board attached. `grcc` compiles the flowgraph
and CI checks that the generated Python parses.
