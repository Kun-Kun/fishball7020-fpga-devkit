# MATLAB

How to use this board from MATLAB and Simulink: what to install, the limits of
MathWorks' ADALM-Pluto support package on this board and the reason for each,
and the `fishball` package and blocks this repository adds to get around them.
Read it before the [MATLAB examples](../examples/matlab/README.md), or when
something in MATLAB reads a level, a channel or a setting that does not match
the board.

```bash
# run from: the repo root, in a SHELL
./devkit matlab            # is MATLAB ready to use this board?
./devkit matlab shell      # interactive, package already on the path
./devkit matlab hello      # run example 01
```

`./devkit matlab` checks the MATLAB side and the board in a few seconds, each
check aimed at a known failure. From a MATLAB prompt the same check is
`fishball.doctor`. If MATLAB is not on `PATH`, set `MATLAB_BIN` to the binary.

---

## Never let MATLAB update your firmware

The Communications Toolbox Support Package for ADALM-Pluto is tested against
Pluto firmware `v0.39`. It sees this board's version, says so, and offers to
**"switch the firmware version"** through the Hardware Setup App.

**Do not.** That image is for an **ADALM-Pluto**: a Zynq-**7010** with an
AD**9363**. This board is a Zynq-**7020** with an AD**9361**: a different FPGA
and a different transceiver, and on the common variant a power amplifier the
Pluto does not have. There is no undo.

`fishball.connect` suppresses that warning and prints the safe half of it
instead, once per session. If you use `sdrrx` directly you see MathWorks'
original, offer and all.

---

## What you need

| | |
|---|---|
| MATLAB | tested with R2026a |
| **Communications Toolbox** | required |
| **ADALM-Pluto support package** | required for live radio; about 1 GB. Tested with 26.1.7 |
| DSP System Toolbox | for `audioDeviceWriter` in example 02's listening mode |
| Simulink | example 06, and the `RxSource`/`TxSink` blocks |
| HDL Coder | **not used.** `ver` lists only licensed products, so if you do not see it you do not have it |

Without the support package you can still run **every analysis here** on a
capture file; see [No support package](#no-support-package) below.

---

## Three things that will bite you

### 1. Full scale is ±2047, and MATLAB is inconsistent with itself

The converters are 12-bit, sign-extended into `int16`. *Full scale* is the
largest value the converter can represent; every dBFS level is relative to it.

| what you asked for | what you get | full scale |
|---|---|---|
| `OutputDataType` `int16` | raw converter counts | **±2047** |
| `OutputDataType` `double` or `single` | counts ÷ **2048** | **±1.0** |
| transmit | MSB-aligned into a 12-bit DAC | **±32767** |

On one signal, `int16` gives 5 counts where `double` gives 0.00244141, and
5 / 0.00244141 = 2048 exactly.

Divide by 32768 and every absolute level is **24.09 dB** low. The error is
uniform, so nothing looks wrong and every ratio (SNR, EVM) is unchanged. Mixing
the two *receive* conventions is 66 dB. `fishball.spectrum` takes a `FullScale`
argument for this reason and defaults to 2047.

### 2. Setting a property on a running object does nothing

Not an error. Nothing. Changing `.Gain` from 10 to 60 on a locked System object
gives six identical frames, while the same gains applied at construction give
rms 0.83 → 27.63.

```matlab
>> % run from: the MATLAB prompt
>> rx.Gain = 40;                      % silently ignored
>> release(rx); rx = fishball.connect('Gain', 40);    % what you meant
```

pyadi-iio has the same trap, where the fix is `rx_destroy_buffer()`.

### 3. MATLAB can only see one of the two receivers

```
ChannelMapping must be equal to 1
```

on **both** `sdrrx` and `sdrtx`. The support package is written throughout for
a 1R1T ADALM-Pluto (one receiver, one transmitter). This board is 2R2T
(`cf-ad9361-lpc` has four scan channels), so RX2 and TX2 *are* reachable, just
not through those objects.

| | RX1 / TX1 | RX2 / TX2 |
|---|---|---|
| receive | `sdrrx` | `fishball.capture2` → `iio_readdev` |
| transmit | `sdrtx` | `fishball.safeTransmit` → `iio_writedev -c` |

Both come back as something `release()` stops, so your code does not branch.

---

## No support package

Every analysis in the examples runs on a capture file, so base MATLAB plus
Communications Toolbox is enough:

```bash
# run from: the repo root
./tools/sigmf-capture.py record air --rate 3e6 --freq 868e6 --seconds 2
```

```matlab
>> % run from: the MATLAB prompt, with the repo root as the current folder
>> addpath matlab
>> [x, meta] = fishball.readSigMF('air.sigmf-meta');
>> [db, f]   = fishball.spectrum(x, meta.SampleRate, 'FullScale', meta.FullScale);
>> plot((meta.CenterFrequency + f)/1e6, db); grid on
```

`readSigMF` reads exactly what `tools/sigmf-capture.py` writes, full scale
included, so a level measured here means the same as one in
[measured-performance.md](measured-performance.md). It matches numpy on the
same file: sample count, first sample, rms to six decimals and peak.

---

## Streaming, and letting the fabric help

MATLAB can only just keep up with a live audio stream from this board. The way
to make it comfortable is to stop doing the work in MATLAB.

Profiled at 2.4 MS/s with 0.2 s frames:

```
read        179.7 ms     <- 90 % of a 200 ms budget
all the DSP  11.3 ms
```

The read is not slow; it is *real-time limited*, because 0.2 s of signal takes
0.2 s to arrive. The processing after it makes each turn cost ~212 ms for
200 ms of audio, so the sound card starves at about 6 % **indefinitely**.
Buffering delays that and does not remove it.

The fix is the **÷8 decimating filter in the FPGA fabric** (the programmable
logic in front of the ARM cores). Engaging it means the host reads 288 kHz
instead of 2.304 MHz: eight times less data and no decimation stage in MATLAB.

```
3.2 s of audio    3.39 s of wall clock  ->  2.64 s
40 s of listening    113 underruns      ->  0
```

There is no "filter on" attribute. Writing the ADC device's
`sampling_frequency` to one eighth of the converter rate *is* what drives
`GP_CONTROL` bit 0 and the bypass mux. **It is only safe on both receivers
because of patch `0021`**: on upstream wiring, or a `STOCK_RX_FILTER=1` build,
engaging it aliases RX2 by about 70 dB. See
[both-receive-channels.md](both-receive-channels.md).

---

## Transmitting

Three examples transmit: **03** (the modulated link), **04** when you pass
`TxChannel` (a reference tone for both receivers, `PadDb` then required), and
**06**'s `fishball_qam16.slx` (`PadDb` defaults to 20).
`fishball.safeTransmit` will not start without `PadDb`. This board reaches about
**+19 dBm** and its own receive input is rated **+2.5 dBm**, so a loopback needs
**at least 20 dB** between them. Nothing on the board can sense what is on the
transmit port (there is no coupler and no detector), so the number has to come
from you.

`safeTransmit` reads the applied attenuation back **off the chip** after the
buffer starts, and stops the transmitter if it disagrees by more than 0.5 dB,
because patch `0005` restores a cached attenuation when a buffer opens.

Releasing a transmitter waits for its `iio_writedev` process to exit before
returning. Without that wait, the kernel's close hook mutes the transmitter
*after* the next object has set and verified its gain: every second transmitter
comes up dead at −89.75 dB with nothing reporting a problem. With it, a gain
sweep through a 20 dB loopback is monotonic, −45 dB → −33.5 dBFS through
−10 dB → −0.1 dBFS, and the chip reports exactly the requested −50, −30 and
−20 dB, with −89.75 dB before and after.

Read [transmitter-safety.md](transmitter-safety.md) before anything radiates.

---

## Simulink

Two blocks live in `matlab/+fishball/`, and neither is the stock ADALM-Pluto
block. Drop a **MATLAB System** block and point it at the class.

| | |
|---|---|
| `fishball.RxSource` | receive. RX1, RX2 or both; the FPGA ÷8 decimator; a telemetry output |
| `fishball.TxSink` | transmit. TX1 or TX2; the sample-locked header pins; a pad guard |

The stock block enforces `ChannelMapping must be equal to 1` in both
directions, so on that path RX2 and TX2 do not exist. That is why these two
blocks exist.

Parameters are grouped in the dialog and named the way the rest of the SDR
world names them (`BasebandSampleRate`, `RFBandwidth`, `RFPort`, `GainSource`,
`SamplesPerFrame`), so what you know from `sdrrx` or from a datasheet
transfers. [Example 06](../examples/matlab/06-simulink/README.md) lists every
dialog group.

### Set "Simulate using" to Interpreted execution

Double-click the block; at the **bottom** of the Block Parameters dialog, below
the parameter groups, is a **Simulate using** dropdown. Change it from
`Code generation` to `Interpreted execution` and press OK. It saves with the
model, so it is once per block. From the command line, with the block selected
(`gcb` is "get current block"):

```matlab
>> % run from: the MATLAB prompt, with the model open and the block selected
>> set_param(gcb, 'SimulateUsing', 'Interpreted execution')
```

This is required, not a preference. These blocks reach the radio through
`iio_readdev` and `iio_attr`, which means `system()`, and `system()` has no
generated equivalent. `coder.extrinsic('system')` does not help. With the
default, **Code generation**, the model fails to compile with
`An error occurred in the block '...' during compile`, which names nothing.
The generators in example 06 set it for you.

### The model can drive the radio

`ControlPorts` turns the levers into **input ports**:

| `ControlPorts` | inputs |
|---|---|
| `'none'` | none; the dialog values are used and fixed |
| `'tune'` | `Fc`, centre frequency in Hz |
| `'full'` | `Fc`, `gain` (dB), `BW` (Hz) |
| `'all'` | `Fc`, `gain1`, `gain2`, `BW`, `gainMode`, `RFport` |

`gain1` and `gain2` are separate because the two receivers differ by about
1.5 dB. The two coded ports:

```
gainMode   0 manual   1 AGC slow attack   2 AGC fast attack   3 hybrid
RFport     1 A Balanced ... 9 C_P, 10 TX Monitor 1, 11 TX Monitor 2
           (this firmware accepts only 1; see below)
```

- **A `NaN` on a port means "leave this alone"**, so a model can drive one lever
  without wiring a constant to every port.
- **A value is pushed only when it changes.** Each change is an `iio_attr` round
  trip of roughly 10–30 ms against a 14 ms frame at 288 kHz, plus a stream
  rebuild. Drive these from something slow (a slider, a staircase, a scan that
  steps once a second), not from a signal that changes every frame.
- **`BasebandSampleRate` and `FabricDecimation` are not inputs.** They change
  the buffer geometry; to sweep them, `release` and re-create the block.

**A change rebuilds the stream, and it has to.** Writing the attribute is not
enough: `iio_readdev`, the FIFO, the socket and the board's DMA ring all hold
samples taken at the old setting, and those arrive first. Over USB at
2.304 MSPS with 4096-sample frames and a tone looped into RX1, a 500 kHz retune
without a rebuild leaves the tone at the old offset for **34 more frames**,
with the LO register reading the new frequency the whole time. The block tears
the stream down and rebuilds it on any applied change, and the new frequency
arrives on frame 1. This is the same conclusion pyadi-iio reaches with
`rx_destroy_buffer()`.

`examples/matlab/06-simulink/fishball_scanner.slx` is the worked example: a
staircase walks the oscillator across 88–108 MHz in 70 looks of 288 kHz.

### Two levers this firmware refuses

Both are real AD9361 attributes, both are offered in the dialog, and this
firmware rejects both with `Invalid argument (22)`:

- **`RFPort`**: only `A_BALANCED` is accepted, although
  `rf_port_select_available` advertises twelve (A/B/C balanced, the six
  single-ended halves, and `TX_MONITOR1/2`, which would point the receiver at
  this board's own transmitter). Refused from an idle ENSM state as readily as
  from a running one.
- **`EnableRxFIR`**: nothing to enable until coefficients are loaded through
  `filter_fir_config`. Design taps with `firmware/scripts/gen_fir_coe.m`.

The three tracking levers (quadrature, RF DC and baseband DC) do apply.

Every write is checked against `iio_attr`'s exit status. When the radio refuses
one, the block **warns once per attribute** with the chip's own message. Once,
not once per frame: these writes sit on a per-frame path, and a warning every
14 ms is a hang, not a diagnostic.

### Rules for System objects that touch the radio

- **Do not open the radio in `setupImpl`.** Simulink calls `setupImpl` when it
  **compiles** the model as well as when it starts it, so a transmitter set up
  there is started, torn down and started again, and the receiver captures the
  silence in between (the model's log reads 1 count of 2047). Open the radio
  lazily on the first step and keep only argument checking in setup. Both blocks
  here do this; `TxSink` still checks `PadDb` in setup, so a bad pad fails
  before anything radiates.
- **Write the transmit gain until the chip agrees.** Patch `0005` restores a
  cached attenuation when the hardware buffer starts, and that moment is not
  when the frame was handed to the FIFO, so a single write can be overwritten.
  `TxSink` rewrites the gain until the read-back matches, up to twelve attempts,
  then stops the transmitter with
  `Asked for ... dB, chip reports ... dB after 12 attempts`.
- **Measure a constellation the way it is drawn.** Normalising the symbols
  before comparing them to the reference (the natural way to write an EVM
  function) measures whether the clusters are *tight*, not whether they are in
  the *right place*. A constellation at 1.42× the reference radius reads 6.3 %
  that way and 42.3 % against the reference as plotted. Check the amplitude
  ratio as well.

### A worked 16-QAM link

`examples/matlab/06-simulink/fishball_qam16.slx` sends 16-QAM out of TX1,
through a cable and a 20 dB pad, back into RX1, and recovers it live into a
constellation diagram. At 900 MHz and 144 ksym/s (576 kbit/s):
**6.7 % EVM as plotted**, amplitude ratio **1.003** to the reference so the
symbols sit *on* the markers, all sixteen decision regions populated 200–280
times against an expected 256, and a peak of 324 counts of 2047, so nothing
clips. It **transmits**: read [transmitter-safety.md](transmitter-safety.md)
first.

It engages the **FPGA ÷8 decimator**, which is what makes it work. At the full
2.304 MSPS MATLAB cannot keep up, the buffers stay full, and what you read is
about **34 frames old**, so the receiver's first frames are from before the
transmitter came up and the constellation is a blob. At 288 kHz the host keeps
up and the link is live.

---

## The firmware version string

The support package expects `v0.39`. On any other version it raises
`plutoradio:sysobj:FirmwareIncompatible`, a message its own catalogue declares
`context="warning"` and whose text reads *"You can continue using version
{1}"*. That message takes five parameters and the package supplies the wrong
**type** for one, so **building the warning throws**, and the throw aborts the
connection:

```
In 'plutoradio:sysobj:FirmwareIncompatible', data type supplied is incorrect
for parameter {1}.
```

Suppressing it does not help: `message()` is constructed before the warning
state is consulted, so even `warning('off','all')` still fails.

Whether it throws depends on the *shape* of `fw_version` in `/etc/libiio.ini`,
not on the version number:

| `fw_version` | result |
|---|---|
| `v2.0`, `2.0`, `v2.0.1`, `v2.0-dirty`, `v0.39`, `v0.39-9-gdeadbeef` | **connects** |
| `v2.0-9-g5ae29d94-dirty`, `v2.0-9-g5ae29d94`, `v2.0-9-gabcdef` | **fails** |

So `fishball-identity` on the board publishes the release in `fw_version` and
the full `git describe` beside it:

```
fw_version=v2.0
fw_build=v2.0-9-g5ae29d94-dirty
```

Nothing in this repository parses `fw_version` (the self-test and the MCP
server only display it), and upstream Pluto firmware reports a clean `v0.38`,
so this follows the existing convention. If a board still reports a describe
string in `fw_version`, MATLAB will not connect and will not say why. Fix it on
the board:

```bash
# run on the board (Debian root, v2.x)
/usr/local/sbin/fishball-identity   # rewrites /etc/libiio.ini
systemctl restart iiod              # iiod reads it when it starts
```

**v1.x (Buildroot) is untested with MATLAB.** Its `fw_version` comes from a
`git describe` on the upstream tree and may or may not have the shape that
breaks it. The fix is the same if it does.

---

## Troubleshooting

| | |
|---|---|
| `No board answered on fishball.local…` | Not on the network, or elsewhere. `BOARD=192.168.2.1 matlab` on the USB cable, or `./devkit status` |
| MATLAB offers to update the firmware | **Refuse.** See [the top of this page](#never-let-matlab-update-your-firmware) |
| Connection dies with `data type supplied is incorrect for parameter {1}` | The [`fw_version` shape](#the-firmware-version-string). Re-run `fishball-identity` on the board |
| `already owned by a block, block dialog, or System object` | A **failed** setup leaves the radio held for the rest of the session, so this is usually left over from an earlier error. `clear all` |
| `-16 EBUSY` | A killed client left a session holding the DMA **on the board**. No host-side action clears it; `killall iiod` over ssh does |
| Everything reads near zero | Your antenna is probably on the other port. `'RxChannel', 2` |
| Audio underruns while listening | See [streaming](#streaming-and-letting-the-fabric-help) |
| Simulink: `An error occurred in the block '...' during compile` | Set the block to [Interpreted execution](#set-simulate-using-to-interpreted-execution) |
| A licence error naming a toolbox | The examples degrade with a message naming it. The SigMF path needs only Communications Toolbox |

---

## Where things are

| | |
|---|---|
| [`matlab/+fishball/`](../matlab/+fishball/) | the package: `connect`, `capture2`, `spectrum`, `phase`, `evm`, `qam`, `safeTransmit`, `readSigMF`, `doctor`, and the Simulink blocks `RxSource` and `TxSink` |
| [`examples/matlab/`](../examples/matlab/) | six examples, receive-first; 06 is Simulink |
| [`tools/matlab.sh`](../tools/matlab.sh) | what `./devkit matlab` runs |
