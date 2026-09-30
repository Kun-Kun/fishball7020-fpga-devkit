# 04 — two coherent receivers

RX1 against RX2: the phase between them, and the coherence that says whether
that phase means anything. A one-channel radio cannot make this measurement.

Receive only, unless you pass `TxChannel`: then it transmits a tone for both
receivers to hear, and `PadDb` is required. The transmitter reaches about
+19 dBm and a receive port is rated +2.5 dBm, so any cable from TX to RX needs
**at least 20 dB** of attenuation in it
([`docs/transmitter-safety.md`](../../../docs/transmitter-safety.md)).

**What you need:** the same signal into **both** RX1 and RX2 for a meaningful
reading, normally a splitter and two cables of known, ideally equal, length.
Two antennas work for a demonstration.

```bash
# run from: the repo root, in a SHELL
./devkit matlab shell
```

```matlab
>> % run from: the MATLAB prompt (./devkit matlab shell puts the example on the path)
>> coherent_rx                                   % 868 MHz, 3 MS/s, 20 blocks
>> coherent_rx('CenterFrequency', 100e6)
>> coherent_rx('Blocks', 40)                     % watch it over time
>> coherent_rx('TxChannel', 1, 'PadDb', 20)      % give both a reference tone (TRANSMITS)
```

## Why this board can do it

RX1 and RX2 are inside **one AD9361**, behind **one local oscillator** and
**one sample clock**. The phase between them is therefore a property of the
signal and the cabling, not of two clocks wandering apart. That is what makes
direction finding and MIMO (multiple-antenna techniques) possible here, and
impractical with two separate receivers.

It is also why `sdrrx` cannot do this: the ADALM-Pluto support package is
written for a 1R1T radio and rejects `ChannelMapping` 2. Both receivers come
from one `iio_readdev`, wrapped as `fishball.capture2`, so the two columns are
from the same buffer and sample-aligned by construction.

## Read coherence before you read phase

*Coherence* is how much the two receivers are hearing the same thing, from 0 to
1. Two independent noise streams correlate to a number that random-walks toward
zero, and the **angle** of that number is a random value that a plot renders
with total confidence. Coherence near 1 means the two inputs are hearing the
same thing and the angle means something. Near 0 means you are reading noise
with a decimal point on it.

With a 20 dB loopback pad on RX1 and an 868 MHz antenna on RX2 (two receivers
hearing different things):

```
  block   coherence      phase      RX1 rms   RX2 rms
      1      0.3757     +11.52 deg       4.5      70.0
      3      0.3766     +11.77 deg       4.5      70.0
      5      0.3797     +12.20 deg       4.5      69.8

  mean coherence     0.3785
  mean phase         +12.00 deg
  phase spread (1SD) 0.29 deg
```

The phase is **very stable**, 0.29° of spread across the run, and it looks like
a solid measurement. It is not: coherence is 0.38, and the example says so
rather than printing the angle alone. An antenna on one port and a loopback pad
on the other is a common bench state, and the correct answer to it is a low
coherence.

## A stable phase is still not a direction

Turning phase into an angle of arrival needs a known baseline, a known geometry
and a calibration of the two chains against each other. This board's two
receivers differ by about **1.5 dB** in sensitivity before you start.

## Rate ceiling

Two channels are clean to about **3 MS/s** on this board and drop samples at
10 MS/s. `iio_readdev` returns the byte count you asked for whether or not the
DMA overflowed, so an over-rate capture **looks perfect and is not**, and
dropped samples destroy exactly what is being measured here.
`fishball.capture2` warns above 4 MS/s.
