# 06 — Simulink

```bash
# run from: the repo root, in a SHELL
./devkit matlab shell
```

```matlab
>> open_system('examples/matlab/06-simulink/fishball_rx.slx')        % a receiver
>> open_system('examples/matlab/06-simulink/fishball_scanner.slx')   % ... that scans
>> open_system('examples/matlab/06-simulink/fishball_qam16.slx')     % a live 16-QAM link
```

The first two are **receive only**. The third **transmits**, and needs TX1
cabled to RX1 through at least a 20 dB attenuator. Press run; a spectrum window
opens.

To rebuild any of them, or point one somewhere else:

```matlab
>> addpath examples/matlab/06-simulink
>> make_fishball_rx_model('CenterFrequency', 100.1e6, 'Open', true)
>> make_fishball_scanner_model('StartFrequency', 400e6, 'StopFrequency', 450e6, 'Open', true)
>> make_fishball_qam16_model('CenterFrequency', 900e6, 'Open', true)
```

## Six files, and why

| | |
|---|---|
| `fishball_rx.slx` | a receiver. Settings live in the dialog and never change |
| `fishball_scanner.slx` | the same receiver **driven by the model** — it retunes as it runs |
| `fishball_qam16.slx` | a **live 16-QAM link** over the board's own loopback. **Transmits** |
| `make_fishball_rx_model.m` | builds the first. Committed so you can **read** it |
| `make_fishball_scanner_model.m` | builds the second |
| `make_fishball_qam16_model.m` | builds the third |

An `.slx` is a binary. It works, and in version control it cannot be reviewed,
diffed or merged — you cannot see what changed between two versions, which is
most of the point of keeping it. So both halves are here, which is the same
arrangement the rest of this repository uses for generated things
(`docs/img/make_*_svg.py`, `docs/course/make_print_html.py`).

If you change a model in Simulink and save it, the two disagree. Change the
generator and re-run it instead, or accept that the `.m` is then stale.

## The custom block, which is the point

The models are built with **`fishball.RxSource`**, a MATLAB System block in this
repository, not the stock ADALM-Pluto block. Three things follow:

| | stock Pluto block | `fishball.RxSource` |
|---|---|---|
| receivers | RX1 only — `ChannelMapping must be equal to 1` | **RX1, RX2 or both**, sample-aligned |
| FPGA ÷8 decimator | no access | `FabricDecimation` 1 or 8 — eight times less data over the network |
| telemetry | none | second output: `[rssi1, rssi2, AD9361 °C, applied gain]` |

`make_fishball_rx_model('Source','pluto')` builds the stock version instead, if
you want to compare.

## The block dialog

Double-click the block. The parameters are grouped, and named the way the rest
of the SDR world names them — `BasebandSampleRate`, `RFBandwidth`, `RFPort`,
`GainSource`, `SamplesPerFrame` — so what you know from `sdrrx`, from ADI's
tools or from a datasheet transfers.

| group | what is in it |
|---|---|
| **Radio** | `RadioID` (libiio URI, blank = find it), `ChannelMapping` — `RX1`, `RX2` or `RX1+RX2` |
| **RF front end** | `CenterFrequency`, `RFBandwidth`, `RFPort` |
| **Gain** | `GainSource` — Manual / AGC Slow Attack / AGC Fast Attack / AGC Hybrid — and `Gain` in dB |
| **Sampling** | `BasebandSampleRate`, `FabricDecimation`, `SamplesPerFrame` |
| **Corrections** | `EnableQuadratureTracking`, `EnableRFDCTracking`, `EnableBasebandDCTracking`, `EnableRxFIR` |
| **Simulink** | `ControlPorts`, `StatusUpdatePeriod` |

`Gain` greys out when `GainSource` is not Manual, because an AGC is choosing it.

> **Manual is usually right on this board.** An AGC counts the receiver's own
> local-oscillator leak as signal and can raise the gain until *that*, not your
> signal, hits its target. Measured at 96 MHz: AGC put the DC bin **29 dB above**
> the station; manual 65 dB put it **31 dB below**.

### Two levers this firmware refuses, and now says so

Both are real AD9361 attributes and the block offers both. Measured on this
board, the driver rejects both with `Invalid argument (22)`:

| lever | what happens |
|---|---|
| `RFPort` | only **A Balanced** is accepted. The chip advertises twelve in `rf_port_select_available` — A/B/C balanced, the six single-ended halves, and TX Monitor 1/2 which would point the receiver at this board's own transmitter with no cable — and every one but `A_BALANCED` is refused, from an idle ENSM state as readily as from a running one |
| `EnableRxFIR` | refused until a set of coefficients is loaded through `filter_fir_config`. There is nothing to enable before that. Design taps with `firmware/scripts/gen_fir_coe.m` |

The three tracking levers — quadrature, RF DC and baseband DC — **do** apply;
verified by reading all three back off both channels after setting them false.

This is worth spelling out because of how it used to fail. Every write in this
block went to `/dev/null`, so a refused setting looked exactly like an applied
one: the dialog said *enabled*, the chip said *0*, and nothing anywhere said
otherwise. Every write is now checked against `iio_attr`'s exit status and a
refusal warns **once per attribute**, with the chip's own message and what to
do about it. Once, not once per frame — these sit on a per-frame path, and a
warning every 14 ms is a hang, not a diagnostic.

## Driving the radio from the model

`ControlPorts` adds **input** ports, so the levers become signals rather than
dialog settings:

| `ControlPorts` | inputs |
|---|---|
| `'none'` | none — the dialog values are used and fixed |
| `'tune'` | `Fc` — centre frequency, Hz |
| `'full'` | `Fc`, `gain` (dB), `BW` (Hz) |
| `'all'` | `Fc`, `gain1`, `gain2`, `BW`, `gainMode`, `RFport` |

`gain1` and `gain2` are separate because the two receivers on this board differ
by about 1.5 dB, so one shared number is a compromise rather than a setting.
The two coded ports:

```
gainMode   0 manual   1 AGC slow attack   2 AGC fast attack   3 hybrid
RFport     1 A Balanced ... 9 C_P, 10 TX Monitor 1, 11 TX Monitor 2
           (but see above — this firmware accepts only 1)
```

**A NaN input means "leave this alone".** Without that you would have to wire a
correct constant to all six ports to drive one. `fishball_scanner.slx` wires
`gainMode` and `RFport` to NaN constants for exactly this reason: the model
commands four of the six and says nothing about the other two.

**A value is only pushed when it changes**, because a change is not free: the
block writes the attribute *and rebuilds the stream*. Drive these from something
slow — a slider, a staircase, a scan that steps once a second — not from a
signal that changes every frame.

> ### Why a change rebuilds the stream
>
> Writing the attribute is not enough. `iio_readdev`, the FIFO, the socket and
> the board's own DMA ring are all holding samples captured at the **old**
> setting, and those come out first.
>
> Measured over USB at 2.304 MSPS with 4096-sample frames, transmitting a tone
> into RX1 through the loopback: after commanding a 500 kHz retune, the tone
> stayed at the old offset for **thirty-four more frames** and only moved on the
> **35th** — with the LO register reading the new frequency the whole time.
>
> That is the trap. Read the register back and the retune looks instant; look at
> the *samples* and it has not happened yet. So the block tears the stream down
> and rebuilds it on any applied change, which is the same conclusion pyadi-iio
> reaches with `rx_destroy_buffer()`. Re-measured after the fix: the new
> frequency arrives on **frame 1**.

**`BasebandSampleRate` and `FabricDecimation` are deliberately not inputs.**
They change the buffer geometry, so altering them means tearing the stream down
and building it again; to sweep those, `release` and re-create. Frequency, gain
and bandwidth need none of that, which is why those are the ones offered.

## `fishball_scanner.slx` — the worked example

A staircase walks the local oscillator across a band, one look at a time, and
the spectrum window redraws at each step. The default sweeps **88–108 MHz in 70
looks of 288 kHz**, 284 ms each — one sweep in about 20 seconds — then stops.

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

Verified against the chip *and* against the samples. A four-step sweep from
89.0 MHz left the local oscillator reading **89 863 998 Hz** against a commanded
89 864 000 — the ±2 Hz is the synthesiser's own resolution. And with a tone fed
into RX1 through the loopback, commanding +500 kHz moved it from +299 812.5 Hz
to −200 250 Hz against a predicted −200 187.5, on the next frame.

Checking the register alone would not have been enough — see the box below.
Each step costs a stream rebuild on top of its dwell, so a sweep takes longer
than dwell × steps.

> ### One rate in the model, or it will not compile
>
> The staircase ticks at the **frame rate** and each frequency is repeated for
> the dwell, rather than the staircase ticking slowly at a rate of its own.
>
> Two rates means Simulink must find a common step, and a dwell written as a
> rounded decimal is not an exact multiple of `4096/288000`. It fails with
>
> ```
> The computed fixed step size (3.3333347135422381E-11) is 1000000.0 times
> smaller than all the discrete sample times in the model
> ```
>
> which is a true statement about a problem you did not know you had. Repeating
> costs nothing — the block pushes a value only when it *changes*, so the 19
> identical frames after each step are free.

> ### It must be set to "Interpreted execution"
>
> **Where the setting is.** Double-click the block. The **Block Parameters**
> dialog opens — the parameter groups are in the middle, and at the very
> **bottom**, below all of them, is a dropdown labelled **Simulate using**.
> Change it from `Code generation` to `Interpreted execution` and press **OK**.
>
> ```
>  ┌─ Block Parameters: Fishball RX ──────────────────────┐
>  │  Fishball7020 SDR Receiver                           │
>  │                                                      │
>  │  ▸ Radio        ▸ RF front end    ▸ Gain             │
>  │  ▸ Sampling     ▸ Corrections     ▸ Simulink         │
>  │                                                      │
>  │  Simulate using: [ Interpreted execution      ▾ ]  ← │
>  ├──────────────────────────────────────────────────────┤
>  │            [ OK ] [ Cancel ] [ Help ] [ Apply ]      │
>  └──────────────────────────────────────────────────────┘
> ```
>
> It is saved **with the model**, so it is once per block, not once per run.
> The same thing from the command line, with the block selected:
>
> ```matlab
> >> set_param(gcb, 'SimulateUsing', 'Interpreted execution')
> ```
>
> `gcb` is *get current block* — whichever block is selected in the model. To
> name it instead: `set_param('fishball_rx/Fishball RX', ...)`.
>
> The generators do this for you. The default is **Code generation**, and this
> block cannot be generated: it reaches the radio through `iio_readdev` and
> `iio_attr`, which means `system()`, and `system()` has no generated
> equivalent. Leave the default and the model fails with:
>
> ```
> An error occurred in the block '...' during compile.
> ```
>
> which names nothing at all. That message cost a long bisect, so here is the
> result: a minimal System object compiles; it still compiles with a
> `StringSet`, `varargout`, two outputs, a constructor, private properties and
> private methods calling each other; and it stops compiling the moment any
> reachable line executes `system('true')`. **`coder.extrinsic('system')` does
> not help.** Interpreted execution does.

## The stock block is RX1 only, and that is not a choice

The stock block is the same support package as `sdrrx`, with the same limit:
`ChannelMapping must be equal to 1`. That is why `fishball.RxSource` exists —
it reaches both receivers, and both arrive in one `N`-by-2 frame from the same
buffer, so they are sample-aligned by construction. See
[example 04](../04-coherent-rx/) for what that is good for.

## The default is a station

`90.4e6` and 2.304 MSPS, because that is a real FM station on the board this was
written against and a model that shows noise on first run teaches nothing. Find
yours with `fm_stations` ([example 02](../02-fm-receiver/)) and rebuild.

2.304 MSPS is chosen so the arithmetic downstream is exact and it clears the
AD9361's 2.083 MSPS floor — see example 02 for why that floor matters.

## `fishball_qam16.slx` — a live 16-QAM link

> **This one transmits.** It needs **TX1 cabled to RX1 through at least 20 dB**
> of attenuation. It never touches TX2. `PadDb` defaults to 20 and the block
> refuses a level that would exceed the receive port's +2.5 dBm rating.

**16-QAM** — quadrature amplitude modulation with sixteen points, so 4 bits per
symbol — goes out of TX1, round the cable, and back into RX1. The model recovers
it live. The constellation diagram *is* the measurement: sixteen points that
stand still and stay separate means the link is working. Smeared blobs mean
noise, a slowly rotating star means the carrier loop is not locked, and a cross
means the symbol timing is not.

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

### The rate plan is the design

| | |
|---|---|
| converter | 2.304 MSPS — what the AD9361 runs at, and what transmit uses |
| **FPGA ÷8 decimator** | **engaged**, so the host receives **288 kHz** |
| symbol rate | 144 ksym/s — **576 kbit/s** at 4 bits a symbol |
| signal width | 194 kHz, comfortably inside the 288 kHz the host sees |
| frames | TX 16384 samples, RX 2048 — **both 7.111 ms**, so one rate in the model |

**The decimator is not an optimisation here, it is what makes the model work at
all.** Receiving the full 2.304 MSPS, MATLAB cannot keep up, so the buffers fill
and stay full and what you read is roughly **34 frames old** — measured. That is
invisible for a static signal and fatal here, because the receiver's first
frames are then all from *before* the transmitter came up. At 288 kHz the host
keeps up, the buffer stays shallow, and the link is genuinely live.

### Measured on the cabled loopback

900 MHz, TX1 at −30 dB through a 20 dB pad into RX1 at 20 dB:

| | |
|---|---|
| EVM, decision directed | **6.2 %** — about 24 dB SNR |
| symbols per decision region | 200–280 against an expected 256, all sixteen populated |
| peak in the raw frame | 300 counts of 2047, so no clipping |

Both numbers were taken by logging the model's **own** signals and measuring
them, not by looking at the picture. The Simulink chain reads 6.24 % and the
same maths on the same capture reads 6.23 %, so the blocks are doing what the
equivalent MATLAB code does.

### Two things that made it a blob, and both were ours

**The transmitter was set up during *compile*.** `TxSink` did all its radio work
in `setupImpl`, and Simulink calls `setupImpl` when it compiles the model as
well as when it starts it. So the transmitter was started, torn down and started
again, and the receiver captured the silence in between: the model's own log
came back at **1 count of 2047**. `RxSource` already avoided this with a
deliberately empty `setupImpl`; `TxSink` now does the same and opens the radio
lazily on its first step. Only the pad arithmetic stays in setup, so a bad
`PadDb` still fails before anything radiates.

**Nothing said which half ran first.** The two halves share no signal, so
Simulink was free to open the receiver before the transmitter. The transmit
block now carries `Priority = -1`.

### The transmitter is a Constant block, which is not a cheat

`fishball.TxSink` runs **Cyclic**: the hardware is handed one buffer and loops it
for ever with no host involvement, and later frames are ignored by design. So a
Constant is exactly the right source — and it sidesteps what makes streaming
transmit from MATLAB painful. Measured, feeding 3 MS/s in 4096-sample frames
produced **732 DMA underflows in one second**. Cyclic has none, because nothing
has to arrive on time.

The waveform is built with a **circular** convolution, not a plain one:

```matlab
txWave = ifft(fft(upsample(sym, sps)) .* fft(h(:), N));
```

A cyclic buffer wraps from the last sample back to the first. Shape the pulses
with a normal filter and there is a discontinuity at that seam, which splatters
across the band once per repeat. Filtering circularly makes the block exactly
periodic and the seam is gone.

### Both radios here share one clock

They are one chip, so there is no frequency offset to chase — only a fixed phase
rotation and a timing offset. A link between two *separate* radios needs the
same blocks working considerably harder, and a Coarse Frequency Compensator in
front.

## Transmitting from Simulink

`fishball.TxSink` is the matching sink — TX1 or TX2, the sample-locked header
pins, and a pad guard that refuses a level which would exceed the receive port's
+2.5 dBm rating. Read its help before you wire one up:

```matlab
>> help fishball.TxSink
```

> ### Releasing one and building another used to race
>
> `release` signalled `iio_writedev` and moved on without waiting for it to go.
> When it finally exited, the kernel's close hook muted the transmitter — by
> which time the *next* object had already set its gain and read it back, so
> nothing reported a problem and the radio sat at −89.75 dB.
>
> It showed up as **every second transmitter coming up dead**. A tone and a gain
> sweep, TX1 → 20 dB pad → RX1:
>
> ```
>   -45 dB -> 50 counts     -40 dB -> 6 counts, chip read -89.75
>   -35 dB -> 150 counts    -30 dB -> 6 counts
>   -25 dB -> 467 counts    -20 dB -> 6 counts
> ```
>
> Teardown now waits for the writer to actually be gone. Re-measured, the same
> sweep is monotonic: −45 dB → −33.5 dBFS through −10 dB → −0.1 dBFS, about a dB
> out per dB in.

## Built with

MATLAB **R2026a** and the Communications Toolbox Support Package for ADALM-Pluto
**26.1.7**. An `.slx` records the release that wrote it and older MATLABs will
refuse to open it; the generator will rebuild it for any release that has the
support package.

Verified: all three models build and simulate against the board, and both radio
models were checked by logging their own signals rather than by looking at the
display. The scanner's retune was checked against the *samples*, not just the LO
register; the 16-QAM model ran 50 frames and demodulated at 6.2 % EVM.

One implementation note worth keeping, because it costs an afternoon otherwise:
the stock library block's **name contains a real newline** — Simulink names it
across two lines and that line break is part of the name. `add_block` therefore
needs `sprintf('plutoradiolib/ADALM-Pluto Radio\nReceiver')`; the same string in
plain single quotes is the two characters backslash-n and matches nothing.
