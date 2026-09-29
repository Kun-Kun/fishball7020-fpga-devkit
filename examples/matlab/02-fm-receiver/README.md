# 02 — FM receiver

```bash
# run from: the repo root, in a SHELL
./devkit matlab shell
```

```matlab
>> fm_receiver('Source', 'synthetic')        % no radio, no antenna - starts here
>> fm_receiver('CenterFrequency', 100.5e6)   % a station near you
>> [a, fs] = fm_receiver('CenterFrequency', 100.5e6); sound(a, fs)
```

Receive only. Nothing here transmits.

## Why this example is really about sample rate

Broadcast FM occupies about 200 kHz, so every Pluto tutorial on the internet
tunes to something like **240 kS/s** and gets on with it. Do that here and the
driver refuses:

> The AD9361 cannot go below **2.083 MSPS** with its own FIR bypassed — a
> 25 MHz minimum ADC clock divided by a maximum divider of 12.

Below that you have to load and enable the chip's internal FIR. If you don't,
**the write fails and the rate stays where it was** while your demodulator
carries on believing it got what it asked for. The symptom is a perfectly
healthy-looking waterfall and static in the speaker — which is one of the two
most common ways to be stuck on this board.

So this captures at a rate the chip will actually give you and decimates in
MATLAB. That costs nothing, and unlike the rate write it cannot fail quietly.
`fm_receiver` refuses a sample rate below the floor rather than letting you
find out the slow way.

## The chain

| stage | rate | what it does |
|---|---|---|
| capture | ≥ 2.083 MSPS | the chip's floor, FIR bypassed |
| decimate | ~240 kHz | now we are in FM territory |
| **discriminator** | — | `angle(x[n] · conj(x[n-1]))` — the frequency *is* the phase advance between samples, and FM put the audio there |
| de-emphasis | — | one pole. **50 µs in Europe, 75 µs in the Americas** — pass `'Deemphasis', 75e-6` |
| decimate | 48 kHz | audio |

The discriminator is three lines written out rather than a toolbox call,
because seeing them is worth more than not seeing them.

## Check it without a radio

```matlab
>> fm_receiver('Source', 'synthetic')
```

Generates a 440 Hz tone at 75 kHz deviation, runs it through the same chain and
should hand back 440 Hz. This is a real test, not a demo: writing the generator
is easy to get wrong and it caught its own bug — a stray `2*pi` in the
modulation index made the true deviation 471 kHz instead of 75 kHz, which
aliased inside the 240 kHz IF and recovered *4839.84 Hz* for a 440 Hz tone.
Exactly 11×, which is what gave it away.

Measured after the fix:

```
  deviation         53.0 kHz rms (75 kHz is full modulation)   <- 75/sqrt(2)
  RECOVERED TONE: 440.19 Hz  (expected 440.00)
```

You can also run it on a capture file, which needs no support package at all:

```bash
# run from: the repo root
./tools/sigmf-capture.py record fm --rate 2.4e6 --freq 100.5e6 --seconds 3
```
```matlab
>> fm_receiver('Source', 'fm.sigmf-meta')
```

## What was and was not verified here

The **chain** is verified against the synthetic source, to 0.19 Hz on a 440 Hz
tone. **Real off-air FM was not** — the board this was written against has an
868 MHz antenna fitted, which is a poor match at 100 MHz. If you have a whip on
the right band, you are testing something the author could not.

Both receivers work: `'RxChannel', 2` goes through `fishball.capture2`, because
`sdrrx` cannot reach RX2 (see [example 01](../01-hello-board/)).
