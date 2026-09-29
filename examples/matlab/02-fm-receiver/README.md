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

## Find a station first — a power scan will lie to you

```matlab
>> fm_stations('RxChannel', 2)
```

This demodulates each candidate and looks for the **19 kHz stereo pilot**: a
narrow, exactly-placed tone that only a broadcast FM station produces. Finding
one is proof; finding power is not.

That distinction cost real time here. A coarse power scan stepping in 1.9 MHz
chunks reported *"96.0 MHz, 38.9 dB above the floor"* as the strongest thing in
the band. There is no station at 96.0 MHz — that was simply the loudest bin
inside a wide step. Meanwhile 90.3 MHz, which the same scan did not mention,
carries a pilot standing **+29 dB** at 18.9990 kHz.

Measured on RX2 here, the ten real ones: 90.40 (+25.9 dB), 95.80, 90.60,
100.20, 104.20, 106.00, 98.60, 101.60, 91.00, 104.80 MHz.

## It stops after a couple of seconds — that is the default, not a fault

By default `fm_receiver` captures `'Seconds'` of IQ (2 by default), demodulates
that block and returns. That is what you want when you are *measuring*
something, and it is emphatically not a radio you can sit and listen to.

To actually listen:

```matlab
>> fm_receiver('Listen', true, 'CenterFrequency', 100.5e6)
>> fm_receiver('Listen', true, 'Duration', 300)     % five minutes
```

That streams frame by frame to the sound card until `Duration` elapses or you
press Ctrl-C. The seams are the awkward part and are handled: the
discriminator needs the sample *before* each frame's first, and the de-emphasis
filter needs its memory, so both are carried across the boundary. Drop either
and you get a click every frame — which sounds like a fault in the radio and is
a fault in the program.

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

## Why AGC is the wrong answer here

A direct-conversion receiver leaks its own local oscillator into its own input,
and that leak lands at DC — the exact centre of what you captured. The AD9361's
AGC counts it as signal and raises the gain until the **leak** hits its target,
leaving the station underneath. Measured at 96 MHz on RX2, comparing the DC bin
against the station:

| gain | DC | station | station vs DC |
|---|---|---|---|
| `slow_attack` | −14.4 dBFS | −43.8 dBFS | **−29.4 dB** |
| manual 65 | −80.7 dBFS | −49.6 dBFS | **+31.1 dB** |
| manual 70 | −77.0 dBFS | −44.9 dBFS | **+32.1 dB** |
| manual 73 | +0.6 dBFS | −45.4 dBFS | −46.0 dB (saturated) |

So the default is **manual 65**, and 65–70 is the usable window. AGC lands
60 dB from the right answer and does it confidently.

The example also uses **offset tuning**: it tunes 400 kHz *below* the station
and shifts back in software, so the LO leak never sits on top of the signal.

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
