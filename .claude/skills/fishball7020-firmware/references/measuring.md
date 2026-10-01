# Measuring this board, and trusting the result

`tools/selftest/sdr_selftest.py` is the instrument. Standard library only, no
`pylibiio`, and it never transmits without `--loopback`.

```bash
# run from: tools/selftest/
./sdr_selftest.py --ssh                                   # no cable, never transmits
./sdr_selftest.py --ssh --loopback --pad 20 --channel 0    # + the RF tests
./sdr_selftest.py --ssh --loopback --pad 20 --channel both # asks you to recable
```

`--pad` is not optional bookkeeping: it is how the tool turns a received level
into absolute power, and how it notices that the loop does not contain what you
think it does, which is the failure that destroys receivers.

## Pitfalls when looking for emissions

**A line sits on exactly 2400.000 MHz, and its source is NOT established.** At
LNA 24 / VGA 20 it reads -76.7 dBFS cabled and still -80.2 dBFS with
**nothing connected to the receiver**, 8 dB over the floor. That is the TX LO
frequency this devkit uses everywhere, so a check for idle emission at 2.4 GHz
finds a line exactly where one is feared. Do not attribute it to any one
clock: 2400.000 MHz is 96 x 25 MHz (a typical instrument reference), 60 x
40 MHz (this board's Y3 VCTCXO), 48 x 50, 100 x 24 and 5 x 480 (USB). Of the
five frequencies probed it is the most composite, so the comb (+2.1, +0.7,
**+8.0**, +2.1, +3.7 dB at 2350, 2375, **2400**, 2425, 2450) singles out no
clock, and since every probe is a multiple of 25 a 25 MHz comb was never
distinguished from a 50 MHz one.

Three controls show only what it is NOT (none tests the board):

- **sweep the transmit attenuator**: a real emission tracks it; this one does
  not (-89.75/-70/-50/-30 dB gave -76.71/-76.72/-76.69/-76.55 dBFS, 0.16 dB over
  60 dB);
- **retune the receive LO**: this one stays pinned at 2400.000;
- **take one capture with the input open**: this one is still there.

**The two controls that WOULD settle it, not yet taken:** capture the frequency
with the **board powered off** (unchanged means the instrument), and terminate
the receiver input in **50 ohm** rather than leaving it open, since an open SMA
is an antenna and a mismatch, not an absence of input.

**Do not use a `/dev/zero` stream as an RF positive control.** I = 0, Q = 0 is
not a signal. `tools/tx-idle-cases/`'s harnesses feed zeros and emit only
residual leakage (+0.40 dB at the TX LO with the attenuator at -30 dB); they
prove the mute through the attenuator read-back, which is their job. Use a
real DDS tone.

**Average before you believe a peak.** The maximum of ONE 2048-bin FFT of noise
sits 8-16 dB above the median and reads exactly like a carrier. `cs8-level.py`
reports a single-FFT peak. Averaging a few thousand FFTs reduces an apparent
"+15 dB bump at the TX LO on a muted board" to 0.2 dB, with the peak at a
different random offset for each receiver centre.

## What is a property of the board, and what is a property of your cable

This distinction decides which numbers mean anything.

**Board properties: ratios, cable-independent.** Gain slopes, image rejection,
harmonic distortion, mute depth, supply rails, die temperature, the digital
interface eye. Quote these freely.

**Setup properties: absolute path loss.** Swapping a single 20 dB pad for a
single 30 dB one moves the whole curve by 10.05 dB (channel 0) and 9.99 dB
(channel 1), median above 200 MHz, so single pads do not distort it. Repeated
passes without touching the cable agree to **0.06 dB above 2 GHz**, 0.3 dB at
1-2 GHz, 0.7 dB at 0.2-1 GHz and up to 5 dB below 200 MHz.

**The board's own TX->RX leak is what limits a loopback.** With the cable off
the RX port, the tone still arrives. Expressed as the pad that would give a
cable loop of the same strength: channel 0 into its own RX 58-77 dB below
1 GHz, 48-60 dB at 1-3 GHz, **33-51 dB at 3-6 GHz**; channel 1 about 10 dB
weaker; the crossed paths 10-35 dB weaker again. The leak and the cable path
add or cancel by frequency, repeatably, so re-running never exposes it. With a
stacked 50 dB pad on channel 0 the response reads up to 13 dB wrong above
1.5 GHz, and re-making the pad joint changes it by only 0.2 dB, so it is not
the connectors. Through 20 dB it is within about +/-2 dB. **Measure through a
single 20 dB pad**, or use a crossed loop above 3 GHz.

That fixed, setup-specific pattern is why the tool compares against a
**baseline you record with your own cable and pad** rather than absolute
thresholds:

```bash
# run from: tools/selftest/
./sdr_selftest.py --ssh --loopback --pad 20 --save-baseline ~/board-healthy.json
./sdr_selftest.py --ssh --loopback --pad 20 --baseline     ~/board-healthy.json
```

`--save-baseline` merges, so a two-channel baseline can be built from two runs.
A baseline is only meaningful against the same cable and pad: do not mix.

## Separating the transmit chain from the receive chain

A straight loopback measures a **product**, `T + R` for one channel, and cannot
say which chain an asymmetry belongs to. Crossing the loop makes the differences
solvable:

```
L00 = T0 + R0     L11 = T1 + R1     L01 = T0 + R1     L10 = T1 + R0
  R0 − R1 = L00 − L01 = L10 − L11        T0 − T1 = L01 − L11 = L00 − L10
```

```bash
# run from: tools/selftest/
./sdr_selftest.py --ssh --loopback --pad 20 --tx-channel 0 --rx-channel 1
```

Absolutes stay unreachable (three equations, four unknowns), but the
differences are fully determined. Measuring both crosses over-determines the
system and gives a closure check needing no external reference:
`L00 + L11 = L01 + L10`. On this board (20 dB pad, 60 frequencies) it closes to
**+0.03 dB median**, with the two routes to each difference agreeing to
0.1-0.15 dB.

Results on this board: channel 1's loop runs about 1.3 dB hotter because its
**receiver** is 1.5 dB more sensitive, not its transmitter (transmitters match
to 0.1-0.25 dB). The 4 GHz step is in the receiver: -3.1 dB in `R0 - R1`,
+0.1 dB in `T0 - T1`.

## Sweeps

```bash
# flags to add to any sdr_selftest.py run
--sweep-points 60 --sweep-start 70e6 --sweep-stop 6e9
```

Log-spaced, clamped to the AD9361's range. The default of 8 points keeps a
routine check fast; 60 costs about 20 seconds. Below 200 MHz points scatter by
up to 5 dB between passes; treat that band as +/-3 dB.

## Reading the output

- **"settings changed on their own"**: something moved the gain or attenuation
  underneath the measurement. It was corrected before measuring, but look for
  the writer (`/mnt/jffs2` on Buildroot, systemd units on Debian).
- **Image rejection "as found" versus "recalibrated"**: the AD9361's
  quadrature calibration goes stale. As found 31–54 dBc; after a forced
  calibration 44–60, 5–7 dB worse into RX2 than RX1, and up to 10 dB apart run
  to run. The check is against the recalibrated figure, because failing on a
  stale one would condemn a good transmitter.
- **"could not vary TX attenuation"**: the sweep had no room, so the tool
  reports no slope rather than one it could not fit.

## Does the kernel affect any of this?

No. On Linux 6.12, TX attenuator linearity, RX gain slope, image rejection,
harmonics, transmit power, mute depth, loop gain, interface eye and digital
loopback all match their 5.15 values, and `./devkit selftest --loopback --pad 20`
reports 32 passed, 0 failed. The table is in
[`docs/measured-performance.md`](../../../../docs/measured-performance.md). Two
entries there look like improvements and are not: image rejection and the
harmonics landed below that capture's noise floor, which makes them bounds
rather than readings, and image rejection on this board varies by up to 10 dB
run to run anyway.

## Verifying the instrument

`tools/selftest/test_dsp.py` asserts the measurement maths against signals whose
answers are known exactly: amplitude calibration lands within 0.004 dB, and the
pure-Python FFT fallback matches numpy to four decimals. CI runs it on Python
3.8 and 3.12, with and without numpy. If a measurement looks wrong, run this
first: it distinguishes a broken board from a broken instrument.
