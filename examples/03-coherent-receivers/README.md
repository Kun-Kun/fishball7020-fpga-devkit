# 03 — Two coherent receivers

The phase between RX1 and RX2, and how much to trust it. RX1 and RX2 live
inside one AD9361, behind one local oscillator and one sample clock, so the
phase between them is a property of the signal and the cabling, not of two
clocks wandering apart. A one-channel radio cannot make this measurement.

Receive only. Nothing here transmits. Put an antenna on **both** RX1 and RX2.

```bash
# run from: the repo root
gnuradio-companion examples/03-coherent-receivers/coherent_rx.grc
```

## What you are looking at

The **cross-correlation** of the two channels: multiply RX1 by the conjugate of
RX2, average, and take the angle of the result. The angle is the phase
difference. The magnitude, normalised, is the *coherence*: how much the two
receivers are hearing the same thing, from 0 to 1.

**Read coherence before you read the angle.** Two independent noise streams
correlate to a number that random-walks toward zero, and its angle is a random
number that the display shows just as confidently as a real one. Coherence near
1 means the two inputs hear the same thing and the angle means something. Near
0 means you are reading noise with a decimal point on it. With 4096 samples per
estimate, independent noise gives about 1/√4096 = 0.016, asserted in
[`../test_blocks.py`](../test_blocks.py).

**The dial**, bottom middle, is a constellation sink used as a polar meter: the
point's angle is the phase, its radius is the coherence, and the unit circle is
the edge of the plot. A dot pinned to the rim is a measurement. A dot wandering
near the origin is not.

## Three things to try, in order

**1. Find a steady carrier and move one antenna a few centimetres.** The angle
moves; put the antenna back and the angle comes back. That repeatability *is*
the coherent-receiver property. Two independent radios would not do this: their
oscillators drift and the phase wanders regardless of the antennas.

**2. Tick `zero`, then move an antenna.** The reading is now relative to where
you zeroed. It latches on the rising edge only; holding the box ticked would
re-zero continuously and the reading would sit at zero whatever the antennas
did. The raw, unzeroed angle stays on its own readout so zeroing can never hide
it.

**3. Widen `band-select` past the LO offset.** Coherence climbs toward 1 and
stays there, steady and convincing, and it is measuring the receiver's own LO
leak correlated with itself. The rest of the flowgraph is arranged to avoid this
failure; seeing it once lets you recognise it elsewhere.

## The controls

| control | live? | what it does |
|---|---|---|
| Sample rate | yes | 2.56–10 MS/s. Two channels, so twice the bytes of one. |
| Centre frequency | yes | 70 MHz to 6 GHz. |
| LO offset | yes | Fraction of span. Keeps the LO leak out of the correlation. |
| Band-select width | yes | 20–3000 kHz. Widen it past the offset to see the trap. |
| RX1 / RX2 gain | yes | Separate, because these two receivers are not identical. |
| Averaging | yes | Estimates in the complex-domain average. Steadier, slower. |
| `zero` | yes | Latches the current phase as the reference, on the rising edge. |
| `chunk` | **no** | Samples per estimate. It is the block's decimation, so it is a port rate and fixed when the flowgraph is built. |

Unequal gains change the amplitudes but **not** the phase. Check it on the
dial: it confirms you are measuring what you think.

## Why the band-select filter is not optional

The receiver's local oscillator leaks into its own mixer, in both channels, and
it is **the same leak**, so it is almost perfectly correlated with itself.
Correlate the raw channels and you measure the leak: coherence pins to 1 and the
angle is a property of the board, not of anything in the air.

So two things happen before the correlation. The LO is offset, putting the leak
away from the signal; and each channel is band-selected around the signal by a
filter **identical** to the other. Whatever phase a filter adds, an identical
filter adds to both channels, and it cancels out of the difference. Two filters
with different taps would make the measurement partly a measurement of the
filters. Both filters read the same `sel_taps` expression for that reason.

## Average the correlation, never the angle

The estimate is `mean(x1 · conj(x2))`, and the angle is taken **after** the
averaging. Averaging angles instead fails silently: angles wrap at ±180°, so a
true phase near 180° has samples landing at +179° and −179°, which average to
roughly zero. Summing complex numbers has no wrap.

[`../test_blocks.py`](../test_blocks.py) asserts this: a true phase of 179°,
noisy enough that individual chunks land on both sides of the boundary, reads
178.7° rather than something near zero.

## Repeatable is not calibrated

Each receive path has its own fixed delay through its own balun and traces, so
there is a phase offset that has nothing to do with what is in the air. `zero`
subtracts it, which makes later readings relative to that moment.

It does **not** make the angle a direction of arrival. That needs a splitter,
matched cables and a known geometry. The offset also changes with frequency, so
zeroing at 2.4 GHz does not hold at 5 GHz.
[measured-performance.md](../../docs/measured-performance.md) has the gain
asymmetry between these two channels (about 1.5 dB of receive gain, which is
normal), and [both-receive-channels.md](../../docs/both-receive-channels.md) has
more on running the pair.

## What is inside

[`../lib/phase_meter.py`](../lib/phase_meter.py), a decimating embedded Python
block: one estimate per `chunk` input samples, which is what a display can use
and about a thousand times less work than one per sample. It publishes the
zeroed phase, the coherence, the raw phase, and `coherence · exp(j·phase)` for
the dial.

## Checking it without a radio

```bash
# run from: the repo root
python3 examples/test_blocks.py
```

This asserts, with no board attached: phases of 0°, 37°, 120° and −95°
recovered to better than 0.5°, coherence above 0.999 for identical inputs and
below 0.06 for independent ones, the ±180° wrap case, and that `zero` latches
once rather than continuously.

## Making a figure

This example has no figure yet. The scripts to make one exist:

```bash
# run from: the repo root
python3 examples/capture_examples.py 03     # one two-channel capture
python3 examples/plot_examples.py 03        # light and dark SVG
```

The capture script takes a single two-channel capture and sweeps the
band-select filter **in software** over those same samples, so the coherence
curve is a property of the filter rather than of what was on the air a minute
later, and it shows the LO-leak trap as a measurement.

If the capture wedges and `dmesg` on the board shows
`ad9361_dig_tune_delay: Tuning TX FAILED!`, the AD9361's digital-interface
tuning has failed. Reboot the board and try again.
