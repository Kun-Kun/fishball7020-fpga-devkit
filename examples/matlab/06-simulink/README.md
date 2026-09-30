# 06 — Simulink

The same radio as a Simulink block diagram: a receiver, a scanner the model
retunes itself, and a live 16-QAM link. The models are built from MATLAB code,
so every change can be read and diffed.

> **`fishball_qam16.slx` transmits.** It needs **TX1 cabled to RX1 through at
> least 20 dB** of attenuation. The board reaches about +19 dBm and the receive
> port is rated +2.5 dBm, so the cable without the pad destroys the receiver.
> The model never touches TX2. Its `PadDb` defaults to 20, and the block refuses
> a level that would exceed the receive port's rating. The other two models are
> **receive only**.

**What you need:** Simulink, Communications Toolbox and the ADALM-Pluto support
package; an antenna on RX1 for the receiver and scanner (both default to the
FM band); the cable and 20 dB pad above for the QAM model.

```bash
# run from: the repo root, in a SHELL
./devkit matlab shell
```

```matlab
>> % run from: the MATLAB prompt, with the repo root as the current folder
>> open_system('examples/matlab/06-simulink/fishball_rx.slx')        % a receiver
>> open_system('examples/matlab/06-simulink/fishball_scanner.slx')   % ... that scans
>> open_system('examples/matlab/06-simulink/fishball_qam16.slx')     % a live 16-QAM link (TRANSMITS)
```

Press run; a spectrum window opens.

To rebuild any of them, or point one somewhere else:

```matlab
>> % run from: the MATLAB prompt, with the repo root as the current folder
>> addpath examples/matlab/06-simulink
>> make_fishball_rx_model('CenterFrequency', 100.1e6, 'Open', true)
>> make_fishball_scanner_model('StartFrequency', 400e6, 'StopFrequency', 450e6, 'Open', true)
>> make_fishball_qam16_model('CenterFrequency', 900e6, 'Open', true)
```

The blocks are documented in [`docs/matlab.md`](../../../docs/matlab.md#simulink);
this page covers the three models.

## What is here

| | |
|---|---|
| `fishball_rx.slx` | a receiver. Settings live in the dialog and never change |
| `fishball_scanner.slx` | the same receiver **driven by the model**: it retunes as it runs |
| `fishball_qam16.slx` | a **live 16-QAM link** over a cabled loopback. **Transmits** |
| `make_fishball_rx_model.m` | builds the first. Committed so you can **read** it |
| `make_fishball_scanner_model.m` | builds the second |
| `make_fishball_qam16_model.m` | builds the third |

An `.slx` is a binary: it works, but version control cannot show what changed
between two versions. So both halves are here, the same arrangement the rest of
this repository uses for generated files (`docs/img/make_*_svg.py`,
`docs/course/make_print_html.py`). If you change a model in Simulink and save
it, the two disagree. Change the generator and re-run it instead, or accept that
the `.m` is then stale.

## The receive block

The models use **`fishball.RxSource`**, a MATLAB System block in this
repository, not the stock ADALM-Pluto block:

| | stock Pluto block | `fishball.RxSource` |
|---|---|---|
| receivers | RX1 only (`ChannelMapping must be equal to 1`) | **RX1, RX2 or both**, sample-aligned |
| FPGA ÷8 decimator | no access | `FabricDecimation` 1 or 8: eight times less data over the network |
| telemetry | none | second output: `[rssi1, rssi2, AD9361 °C, applied gain]` |

The stock block is the same support package as `sdrrx`, with the same one-channel
limit. `RxSource` delivers both receivers in one `N`-by-2 frame from the same
buffer, so they are sample-aligned by construction; see
[example 04](../04-coherent-rx/) for what that is good for.
`make_fishball_rx_model('Source','pluto')` builds the stock version instead, if
you want to compare.

### The block dialog

Double-click the block. The parameters are grouped, and named the way the rest
of the SDR world names them, so what you know from `sdrrx`, from ADI's tools or
from a datasheet transfers.

| group | what is in it |
|---|---|
| **Radio** | `RadioID` (libiio URI, blank = find it), `ChannelMapping`: `RX1`, `RX2` or `RX1+RX2` |
| **RF front end** | `CenterFrequency`, `RFBandwidth`, `RFPort` |
| **Gain** | `GainSource` (Manual / AGC Slow Attack / AGC Fast Attack / AGC Hybrid) and `Gain` in dB |
| **Sampling** | `BasebandSampleRate`, `FabricDecimation`, `SamplesPerFrame` |
| **Corrections** | `EnableQuadratureTracking`, `EnableRFDCTracking`, `EnableBasebandDCTracking`, `EnableRxFIR` |
| **Simulink** | `ControlPorts`, `StatusUpdatePeriod` |

`Gain` greys out when `GainSource` is not Manual, because an AGC is choosing it.

- **Manual gain is usually right on this board.** An AGC counts the receiver's
  own local-oscillator leak as signal and can raise the gain until *that*, not
  your signal, hits its target. At 96 MHz, AGC puts the DC bin **29 dB above**
  the station; manual 65 dB puts it **31 dB below**.
- **Two levers are refused by this firmware** with `Invalid argument (22)`:
  `RFPort` accepts only **A Balanced**, and `EnableRxFIR` needs coefficients
  loaded through `filter_fir_config` first (design taps with
  `firmware/scripts/gen_fir_coe.m`). The three tracking levers do apply. The
  block warns once per refused attribute, with the chip's own message. Details
  in [`docs/matlab.md`](../../../docs/matlab.md#two-levers-this-firmware-refuses).

### "Simulate using" must be Interpreted execution

Double-click the block. The **Block Parameters** dialog opens; the parameter
groups are in the middle, and at the very **bottom**, below all of them, is a
dropdown labelled **Simulate using**. Change it from `Code generation` to
`Interpreted execution` and press **OK**.

```
 ┌─ Block Parameters: Fishball RX ──────────────────────┐
 │  Fishball7020 SDR Receiver                           │
 │                                                      │
 │  ▸ Radio        ▸ RF front end    ▸ Gain             │
 │  ▸ Sampling     ▸ Corrections     ▸ Simulink         │
 │                                                      │
 │  Simulate using: [ Interpreted execution      ▾ ]  ← │
 ├──────────────────────────────────────────────────────┤
 │            [ OK ] [ Cancel ] [ Help ] [ Apply ]      │
 └──────────────────────────────────────────────────────┘
```

It is saved **with the model**, so it is once per block, not once per run. The
same thing from the command line (`gcb` is *get current block*, whichever block
is selected):

```matlab
>> % run from: the MATLAB prompt, with the model open and the block selected
>> set_param(gcb, 'SimulateUsing', 'Interpreted execution')
>> % or name the block instead of selecting it:
>> set_param('fishball_rx/Fishball RX', 'SimulateUsing', 'Interpreted execution')
```

The generators set it for you. With the default, the model fails with
`An error occurred in the block '...' during compile.`, which names nothing:
the block reaches the radio through `system()`, which cannot be code-generated.
[`docs/matlab.md`](../../../docs/matlab.md#set-simulate-using-to-interpreted-execution)
has the detail.

## Driving the radio from the model

`ControlPorts` adds **input** ports, so the levers become signals rather than
dialog settings: `'tune'` gives you `Fc`; `'full'` adds `gain` and `BW`;
`'all'` gives `Fc`, `gain1`, `gain2`, `BW`, `gainMode` and `RFport`. The full
table and the coded values are in
[`docs/matlab.md`](../../../docs/matlab.md#the-model-can-drive-the-radio).
Three rules:

- **A `NaN` input means "leave this alone".** `fishball_scanner.slx` wires
  `gainMode` and `RFport` to NaN constants: the model commands four of the six
  ports and says nothing about the other two.
- **A value is pushed only when it changes**, because each change writes the
  attribute *and rebuilds the stream* (otherwise the samples already in flight,
  up to 34 frames, arrive at the old setting). Drive these ports from something
  slow: a slider, a staircase, a scan that steps once a second.
- **`BasebandSampleRate` and `FabricDecimation` are not inputs.** They change
  the buffer geometry; to sweep them, `release` and re-create.

## `fishball_scanner.slx`: the worked example

A staircase walks the local oscillator across a band, one look at a time, and
the spectrum window redraws at each step. The default sweeps **88–108 MHz in 70
looks of 288 kHz**, 20 frames (284 ms) each, one sweep in about 20 seconds,
then stops. Each step also costs a stream rebuild, so a sweep takes longer than
dwell × steps.

```
sweep ──────────────► Fc     ┌─────────────┐
gain1 ──────────────► gain1  │  Fishball   │── IQ ─────► Spectrum Analyzer
gain2 ──────────────► gain2  │     RX      │
BW ─────────────────► BW     │             │── status ─► [rssi1 rssi2 °C gain]
NaN ────────────────► gainMode
NaN ────────────────► RFport └─────────────┘
```

The step is **one look wide, not a round 1 MHz**. With 288 kHz of bandwidth a
1 MHz step would skip 70 % of the band and look like a scan that found nothing.

What a correct retune looks like, checked against the chip *and* the samples: a
four-step sweep from 89.0 MHz leaves the local oscillator reading
**89 863 998 Hz** against a commanded 89 864 000 (±2 Hz is the synthesiser's
resolution). With a tone fed into RX1 through the loopback, commanding
+500 kHz moves it from +299 812.5 Hz to −200 250 Hz, against a predicted
−200 187.5, on the next frame.

**One rate in the model, or it will not compile.** The staircase ticks at the
**frame rate** and repeats each frequency for the dwell, rather than ticking
slowly at a rate of its own. Two rates make Simulink find a common step, and a
dwell written as a rounded decimal is not an exact multiple of `4096/288000`.
It fails with:

```
The computed fixed step size (3.3333347135422381E-11) is 1000000.0 times
smaller than all the discrete sample times in the model
```

Repeating costs nothing: the block pushes a value only when it *changes*, so
the 19 identical frames after each step are free.

## The default is a station

`fishball_rx.slx` defaults to `90.4e6` at 2.304 MSPS, gain 45, because a model
that shows only noise on first run teaches nothing. 90.4 MHz is a station where
the models were built; find yours with `fm_stations`
([example 02](../02-fm-receiver/)) and rebuild. 2.304 MSPS makes the
arithmetic downstream exact and clears the AD9361's 2.083 MSPS floor; example
02 explains why that floor matters.

## `fishball_qam16.slx`: a live 16-QAM link

**16-QAM** (quadrature amplitude modulation with sixteen points, so 4 bits per
symbol) goes out of TX1, round the cable, and back into RX1. The model recovers
it live. The constellation diagram *is* the measurement: sixteen points that
stand still and stay separate mean the link works. Smeared blobs mean noise, a
slowly rotating star means the carrier loop is not locked, and a cross means
the symbol timing is not.

```
 Constant ──► Fishball TX (TX1, Cyclic)        [the cable + 20 dB pad]
 txWave                                              │
                                                     ▼
 Fishball RX (RX1) ──► int16→double ──► ×1/2047 ──► AGC ──► RRC receive
        │                                                        │
        ├──► Spectrum Analyzer                          Symbol Synchronizer
        └──► radio status                                        │
                                                        Carrier Synchronizer
                                                                 │
                                                        Constellation Diagram
```

### The rate plan

| | |
|---|---|
| converter | 2.304 MSPS: what the AD9361 runs at, and what transmit uses |
| **FPGA ÷8 decimator** | **engaged**, so the host receives **288 kHz** |
| symbol rate | 144 ksym/s: **576 kbit/s** at 4 bits a symbol |
| signal width | 194 kHz, inside the 288 kHz the host sees |
| frames | TX 16384 samples, RX 2048: **both 7.111 ms**, so one rate in the model |

**The decimator is what makes the model work at all.** At the full 2.304 MSPS,
MATLAB cannot keep up, so the buffers fill and stay full and what you read is
roughly **34 frames old**. That is invisible for a static signal and fatal here,
because the receiver's first frames are then all from *before* the transmitter
came up. At 288 kHz the host keeps up, the buffer stays shallow, and the link is
live.

### What you should see

900 MHz, TX1 at −30 dB through a 20 dB pad into RX1 at 20 dB, over 50 frames,
taken from the model's **own** logged signals rather than from the picture:

| | |
|---|---|
| EVM **as plotted**, against the red reference points | **6.7 %**, about 23 dB SNR |
| amplitude ratio to the reference | **1.003**: the symbols sit *on* the crosses |
| symbols per decision region | 200–280 against an expected 256, all sixteen populated |
| peak in the raw frame | 324 counts of 2047, so no clipping |

### Why the AGC targets `1/rxSps` and not 1

This decides whether the sixteen tight blobs are *in the right place*, and
nothing errors when it is wrong.

The AGC normalises the stream it sees, and that stream is still
**oversampled** at `rxSps` samples per symbol. Decimating to symbol instants
picks the matched filter's peaks, and the mean power goes up by exactly the
oversampling factor. Target 1 and the symbols arrive at power `rxSps`:

| AGC target | received mean power | amplitude vs reference | EVM as plotted |
|---|---|---|---|
| `1` | 2.013 | **1.419**: every point 42 % too far out | **42.3 %** |
| `1/rxSps` | 1.068 | **1.034** | **6.8 %** |

The reference constellation is `qammod(..., 'UnitAveragePower', true)`, so the
symbols have to *arrive* at unit average power to land on it. Normalising the
symbols before comparing them to the reference measures only whether the
clusters are tight: with the AGC at 1 that reads 6.3 % while every point misses
its cross by 42 %. Check the amplitude ratio as well as the EVM.

### How the model is put together

- **The transmitter opens on its first step, not in `setupImpl`.** Simulink
  calls `setupImpl` at compile time as well as at start, so a transmitter opened
  there is started, torn down and started again, and the receiver captures the
  silence between (the log reads 1 count of 2047). Only the pad arithmetic runs
  in setup, so a bad `PadDb` still fails before anything radiates.
- **The transmit block has `Priority = -1`.** The two halves share no signal, so
  without it Simulink is free to open the receiver before the transmitter.
- **The transmitter is a Constant block.** `fishball.TxSink` runs **Cyclic**:
  the hardware is handed one buffer and loops it with no host involvement, and
  later frames are ignored by design. So a Constant is the right source, and it
  avoids the problem with streaming transmit from MATLAB: 3 MS/s in 4096-sample
  frames produces **732 DMA underflows in one second**. Cyclic has none,
  because nothing has to arrive on time.
- **The waveform uses circular convolution:**

  ```matlab
  % not a command: the idea, as make_fishball_qam16_model.m does it
  txWave = ifft(fft(upsample(sym, sps)) .* fft(h(:), N));
  ```

  A cyclic buffer wraps from the last sample back to the first. Shape the
  pulses with an ordinary filter and there is a discontinuity at that seam,
  which splatters across the band once per repeat. Filtering circularly makes
  the block exactly periodic and removes the seam.
- **Both radios share one clock.** They are one chip, so there is no frequency
  offset to chase, only a fixed phase rotation and a timing offset. A link
  between two *separate* radios needs the same blocks working harder, and a
  Coarse Frequency Compensator in front.

## Transmitting from Simulink

`fishball.TxSink` is the matching sink: TX1 or TX2, the sample-locked header
pins, and a pad guard that refuses a level which would exceed the receive
port's +2.5 dBm rating. Read its help before you wire one up:

```matlab
>> % run from: the MATLAB prompt, with the repo root as the current folder
>> addpath matlab
>> help fishball.TxSink
```

It waits for its `iio_writedev` to exit on release (otherwise every second
transmitter comes up muted), and rewrites the gain until the chip agrees, up to
twelve attempts, because patch `0005` can restore a cached attenuation after
the first write. A refusal looks like:

```
Asked for -20.00 dB, chip reports -30.00 dB after 12 attempts. Transmitter stopped.
```

[`docs/matlab.md`](../../../docs/matlab.md#rules-for-system-objects-that-touch-the-radio)
has both rules in full.

## Built with

MATLAB **R2026a** and the Communications Toolbox Support Package for ADALM-Pluto
**26.1.7**. An `.slx` records the release that wrote it, and older MATLABs
refuse to open it; the generators rebuild it for any release that has the
support package.

All three models build and simulate against the board.

**If you write your own generator:** the stock library block's **name contains a
real newline**. Simulink names it across two lines and that line break is part
of the name, so `add_block` needs
`sprintf('plutoradiolib/ADALM-Pluto Radio\nReceiver')`. The same string in plain
single quotes is the two characters backslash-n and matches nothing.
