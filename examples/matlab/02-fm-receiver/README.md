# 02 — FM receiver

Broadcast FM to audio, with the demodulator written out so you can see it. The
example is really about sample rate: why you cannot ask this chip for the
240 kS/s every Pluto FM tutorial uses, and how the FPGA's decimating filter
makes continuous listening possible.

Receive only. Nothing here transmits. For real stations you need an antenna
that works around 100 MHz; the synthetic source needs nothing.

```bash
# run from: the repo root, in a SHELL
./devkit matlab shell
```

```matlab
>> % run from: the MATLAB prompt (./devkit matlab shell puts the example on the path)
>> fm_receiver('Source', 'synthetic')        % no radio, no antenna - start here
>> fm_receiver('CenterFrequency', 100.5e6)   % a station near you
>> [a, fs] = fm_receiver('CenterFrequency', 100.5e6); sound(a, fs)
```

## Find a station first

```matlab
>> % run from: the MATLAB prompt
>> fm_stations('RxChannel', 2)
```

`fm_stations` steps across 87.5–108 MHz in 200 kHz steps, demodulates each
candidate and looks for the **19 kHz stereo pilot**: a narrow, exactly-placed
tone that only a broadcast FM station produces. Finding a pilot is proof;
finding power is not.

A power scan misleads here. A coarse scan in 1.9 MHz steps reports the loudest
bin inside each step, which can be a frequency with no station on it (a
"station" 38.9 dB above the floor at 96.0 MHz, where there is none), and it can
miss a real station that carries a pilot +29 dB above the floor. The output
lists the stations whose pilot it found, strongest first, with the pilot level:
`90.40 (+25.9 dB), 95.80, 90.60, 100.20, …`.

## It stops after a couple of seconds by default

By default `fm_receiver` captures `'Seconds'` of IQ (2 s), demodulates that
block and returns. That is what you want when you are *measuring* something,
and it is not a radio you can sit and listen to.

To listen:

```matlab
>> % run from: the MATLAB prompt
>> fm_receiver('Listen', true, 'CenterFrequency', 100.5e6)   % 30 s by default
>> fm_receiver('Listen', true, 'Duration', 300)              % five minutes
```

That streams frame by frame to the sound card until `Duration` elapses or you
press Ctrl-C. The discriminator needs the sample *before* each frame's first,
and the de-emphasis filter needs its memory, so both are carried across frame
boundaries. Drop either and you get a click every frame, which sounds like a
fault in the radio and is a fault in the program.

## Why this example is really about sample rate

Broadcast FM occupies about 200 kHz, so most Pluto tutorials tune to something
like **240 kS/s**. Do that here and the driver refuses:

> The AD9361 cannot go below **2.083 MSPS** with its own FIR bypassed: a
> 25 MHz minimum ADC clock divided by a maximum divider of 12.

Below that you have to load and enable the chip's internal FIR filter. If you
do not, **the write fails and the rate stays where it was** while your
demodulator carries on believing it got what it asked for. The symptom is a
healthy-looking waterfall and static in the speaker, one of the two most common
ways to get stuck on this board.

So this example captures at a rate the chip will give you and decimates
afterwards. That costs nothing, and unlike the rate write it cannot fail
quietly. `fm_receiver` refuses a sample rate below the floor.

The default converter rate is **2.304 MSPS** because the arithmetic is exact:
÷8 = 288 kHz, ÷6 = 48 kHz audio, and 2.304 clears the 2.083 MSPS floor.

## The chain

| stage | rate | what it does |
|---|---|---|
| capture | ≥ 2.083 MSPS | the chip's floor, FIR bypassed |
| decimate | ~240–288 kHz | down to FM territory (the FPGA does this step when listening) |
| **discriminator** | — | `angle(x[n] · conj(x[n-1]))`: the frequency *is* the phase advance between samples, and FM put the audio there |
| de-emphasis | — | one pole. **50 µs in Europe (the default), 75 µs in the Americas**: pass `'Deemphasis', 75e-6` |
| decimate | 48 kHz | audio |

The discriminator is three lines written out rather than a toolbox call, so you
can see it.

## Continuous listening needs the FPGA filter

Profiled at 0.2 s frames, decimating in MATLAB:

```
read        179.7 ms      <- 90 % of a 200 ms budget
shiftDown     3.9 ms
decimate10    4.2 ms
discrim       1.1 ms
lowpass       1.6 ms
decimate5     0.5 ms
TOTAL       191.1 ms      (budget 200 ms)
```

The read is not slow; it is *real-time limited*: 0.2 s of signal takes 0.2 s to
arrive. The 11 ms of processing after it makes each turn cost ~212 ms for
200 ms of audio, so the sound card starves at about 6 % indefinitely. Buffering
only delays that: 20 s is clean, 45 s gives 113 underruns. Shorter frames make
it **worse** (0.08 s frames give 129 underruns, 0.20 s give 21) because
per-frame overhead dominates, and an elastic buffer between `iio_readdev` and
MATLAB removes the read jitter but not the drift.

The fix is to not do the work in MATLAB:

> The board has a **÷8 decimating filter in the FPGA fabric**. Engaging it
> means the host reads 288 kHz instead of 2.304 MHz: eight times less data,
> and no decimation stage in MATLAB. 3.2 s of audio takes **2.64 s** of wall
> clock instead of 3.39 s, and 40 s of listening has **zero** underruns
> instead of 113.

There is no "filter on" attribute. Writing the ADC device's `sampling_frequency`
to one eighth of the converter rate *is* what drives `GP_CONTROL` bit 0 and the
bypass mux. Because of patch `0021` that filter is on **both** receivers, so RX2
is properly anti-aliased; on upstream wiring, engaging it would alias RX2 by
about 70 dB. [`docs/matlab.md`](../../../docs/matlab.md#streaming-and-letting-the-fabric-help)
has more.

## Why the gain is manual

A direct-conversion receiver leaks its own local oscillator (LO) into its own
input, and that leak lands at DC: the exact centre of what you captured. The
AD9361's AGC (automatic gain control) counts it as signal and raises the gain
until the **leak** hits its target, leaving the station underneath. At 96 MHz on
RX2, comparing the DC bin against the station:

| gain | DC | station | station vs DC |
|---|---|---|---|
| `slow_attack` | −14.4 dBFS | −43.8 dBFS | **−29.4 dB** |
| manual 65 | −80.7 dBFS | −49.6 dBFS | **+31.1 dB** |
| manual 70 | −77.0 dBFS | −44.9 dBFS | **+32.1 dB** |
| manual 73 | +0.6 dBFS | −45.4 dBFS | −46.0 dB (saturated) |

So the default is **manual 65**, and 65–70 is the usable window. AGC lands
60 dB from the right answer.

With manual gain the LO leak sits 31 dB below the station, so `fm_receiver`
tunes straight to the station: `OffsetHz` defaults to 0. Offset tuning (tuning
beside the station and shifting back in software) would not fit anyway, because
the fabric decimator keeps only ±144 kHz of a 2.304 MSPS capture and a 400 kHz
offset falls outside it. `fm_stations` does tune 400 kHz off, since it
decimates in MATLAB.

## Check it without a radio

```matlab
>> % run from: the MATLAB prompt
>> fm_receiver('Source', 'synthetic')
```

This generates a 440 Hz tone at 75 kHz deviation, runs it through the same chain
and should hand back 440 Hz:

```
  deviation         53.0 kHz rms (75 kHz is full modulation)   <- 75/sqrt(2)
  RECOVERED TONE: 440.19 Hz  (expected 440.00)
```

You can also run it on a capture file, which needs no support package:

```bash
# run from: the repo root
./tools/sigmf-capture.py record fm --rate 2.4e6 --freq 100.5e6 --seconds 3
```

```matlab
>> % run from: the MATLAB prompt, with the repo root as the current folder
>> fm_receiver('Source', 'fm.sigmf-meta')
```

## Test status

The **chain** is tested against the synthetic source, to 0.19 Hz on a 440 Hz
tone. **Real off-air FM is not tested**: the test board has an 868 MHz antenna,
which is a poor match at 100 MHz.

Both receivers work: `'RxChannel', 2` goes through `fishball.capture2`, because
`sdrrx` cannot reach RX2 (see [example 01](../01-hello-board/)).
