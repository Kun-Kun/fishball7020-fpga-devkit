# 06 — Simulink

```bash
# run from: the repo root, in a SHELL
./devkit matlab shell
```

```matlab
>> open_system('examples/matlab/06-simulink/fishball_rx.slx')        % a receiver
>> open_system('examples/matlab/06-simulink/fishball_scanner.slx')   % ... that scans
```

Receive only. Neither model transmits. Press run; a spectrum window opens.

To rebuild either, or point it somewhere else:

```matlab
>> addpath examples/matlab/06-simulink
>> make_fishball_rx_model('CenterFrequency', 100.1e6, 'Open', true)
>> make_fishball_scanner_model('StartFrequency', 400e6, 'StopFrequency', 450e6, 'Open', true)
```

## Four files, and why

| | |
|---|---|
| `fishball_rx.slx` | a receiver. Settings live in the dialog and never change |
| `fishball_scanner.slx` | the same receiver **driven by the model** — it retunes as it runs |
| `make_fishball_rx_model.m` | builds the first. Committed so you can **read** it |
| `make_fishball_scanner_model.m` | builds the second |

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

**A value is only pushed when it changes**, because each change is an `iio_attr`
round trip of roughly 10–30 ms against a 14 ms frame at 288 kHz. Drive these
from something slow — a slider, a staircase, a scan that steps once a second —
not from a signal that changes every frame.

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

Verified against the chip: a four-step sweep from 89.0 MHz left the local
oscillator reading **89 863 998 Hz** against a commanded 89 864 000 — the ±2 Hz
is the synthesiser's own resolution. The model really does retune the radio.

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

## Transmitting from Simulink

`fishball.TxSink` is the matching sink — TX1 or TX2, the sample-locked header
pins, and a pad guard that refuses a level which would exceed the receive port's
+2.5 dBm rating. Neither model here uses it, deliberately. Read its help before
you wire one up:

```matlab
>> help fishball.TxSink
```

## Built with

MATLAB **R2026a** and the Communications Toolbox Support Package for ADALM-Pluto
**26.1.7**. An `.slx` records the release that wrote it and older MATLABs will
refuse to open it; the generator will rebuild it for any release that has the
support package.

Verified: both models build, and the scanner simulates against the board with
the local oscillator read back off the chip at each step.

One implementation note worth keeping, because it costs an afternoon otherwise:
the stock library block's **name contains a real newline** — Simulink names it
across two lines and that line break is part of the name. `add_block` therefore
needs `sprintf('plutoradiolib/ADALM-Pluto Radio\nReceiver')`; the same string in
plain single quotes is the two characters backslash-n and matches nothing.
