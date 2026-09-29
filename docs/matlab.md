# MATLAB

This board works with MATLAB, and the path there has three sharp edges that are
not obvious and not documented by anyone else. This page is mostly about those.

```bash
# run from: the repo root, in a SHELL
./devkit matlab            # is MATLAB ready to use this board?
./devkit matlab shell      # interactive, package already on the path
./devkit matlab hello      # run example 01
```

`./devkit matlab` checks the MATLAB side and the board in a few seconds, and
every check it makes is one that has already cost somebody time.

---

## > Never let MATLAB update your firmware

The Communications Toolbox Support Package for ADALM-Pluto was tested against
Pluto firmware `v0.39`. It will see this board's version, say so, and offer to
**"switch the firmware version"** through the Hardware Setup App.

**Do not.** That image is for an **ADALM-Pluto**: a Zynq-**7010** with an
AD**9363**. This board is a Zynq-**7020** with an AD**9361** — a different FPGA
and a different transceiver, and on the common variant a power amplifier the
Pluto does not have. There is no undo.

`fishball.connect` suppresses that warning and prints the safe half of it
instead, once per session. If you use `sdrrx` directly you will see MathWorks'
original, offer and all.

---

## What you need

| | |
|---|---|
| MATLAB | R2026a is what this was written and verified against |
| **Communications Toolbox** | required |
| **ADALM-Pluto support package** | required for live radio; about 1 GB |
| DSP System Toolbox | for `audioDeviceWriter` in example 02's listening mode |
| Simulink | example 06, and the `RxSource`/`TxSink` blocks |
| HDL Coder | **not used.** `ver` lists only licensed products, so if you do not see it you do not have it |

Without the support package you can still run **every analysis here** on a
capture file — see [no support package](#no-support-package) below.

---

## Three things that will bite you

### 1. Full scale is ±2047, and MATLAB is inconsistent with itself

The converters are 12-bit sign-extended into `int16`.

| what you asked for | what you get | full scale |
|---|---|---|
| `OutputDataType` `int16` | raw converter counts | **±2047** |
| `OutputDataType` `double` or `single` | counts ÷ **2048** | **±1.0** |
| transmit | MSB-aligned into a 12-bit DAC | **±32767** |

Measured on one signal: `int16` gave 5 counts where `double` gave 0.00244141,
and 5 / 0.00244141 = 2048 exactly.

Divide by 32768 and every absolute level is **24.09 dB** low — uniformly, so
nothing looks wrong and every ratio (SNR, EVM) is unchanged. Mixing the two
*receive* conventions is 66 dB. `fishball.spectrum` takes a `FullScale`
argument for exactly this reason and defaults to 2047.

### 2. Setting a property on a running object does nothing

Not an error. Nothing. Measured: `.Gain` changed from 10 to 60 on a locked
System object gave six identical frames, while the same gains applied at
construction gave rms 0.83 → 27.63.

```matlab
>> rx.Gain = 40;                      % silently ignored
>> release(rx); rx = fishball.connect('Gain', 40);    % what you meant
```

pyadi-iio has the same trap, where the fix is `rx_destroy_buffer()`.

### 3. MATLAB can only see one of the two receivers

```
ChannelMapping must be equal to 1
```

on **both** `sdrrx` and `sdrtx`. The support package is written throughout for
a 1R1T ADALM-Pluto. This board is 2R2T — `cf-ad9361-lpc` has four scan channels
— so RX2 and TX2 *are* reachable, just not through those objects.

| | RX1 / TX1 | RX2 / TX2 |
|---|---|---|
| receive | `sdrrx` | `fishball.capture2` → `iio_readdev` |
| transmit | `sdrtx` | `fishball.safeTransmit` → `iio_writedev -c` |

Both come back as something `release()` stops, so your code does not branch.

---

## The firmware version, and why this repo changed it

MATLAB could not connect to this board at all until September 2026, and the
reason is a **bug in the support package**, not a rejection.

It expects `v0.39`. On anything else it raises
`plutoradio:sysobj:FirmwareIncompatible` — a message its own catalogue declares
`context="warning"` and whose text reads *"You can continue using version
{1}"*. That message takes five parameters and the package supplies the wrong
**type** for one, so **building the warning throws**, and the throw aborts the
connection:

```
In 'plutoradio:sysobj:FirmwareIncompatible', data type supplied is incorrect
for parameter {1}.
```

Suppressing it does not help — `message()` is constructed before the warning
state is consulted, so even `warning('off','all')` still fails.

Measured by editing `/etc/libiio.ini` on a running board and restarting `iiod`
between each:

| `fw_version` | result |
|---|---|
| `v2.0`, `2.0`, `v2.0.1`, `v2.0-dirty`, `v0.39`, `v0.39-9-gdeadbeef` | **connects** |
| `v2.0-9-g5ae29d94-dirty`, `v2.0-9-g5ae29d94`, `v2.0-9-gabcdef` | **fails** |

It is the `git describe` *shape* that breaks it, not the version number.

So `fishball-identity` now publishes the release in `fw_version` and the full
build description beside it:

```
fw_version=v2.0
fw_build=v2.0-9-g5ae29d94-dirty
```

Nothing in this repository parses `fw_version` — the self-test and the MCP
server only display it — and upstream Pluto firmware reports a clean `v0.38`,
so this is a return to the convention rather than a departure. **If your board
predates that change**, re-run `/usr/local/sbin/fishball-identity` and restart
`iiod`, or MATLAB will not connect and will not tell you why.

**v1.x (Buildroot) is untested with MATLAB.** Its `fw_version` comes from a
`git describe` on the upstream tree and may or may not have the shape that
breaks it. The fix is the same one line if it does.

---

## No support package

Every analysis in the examples runs on a capture file, so base MATLAB plus
Communications Toolbox is enough:

```bash
# run from: the repo root
./tools/sigmf-capture.py record air --rate 3e6 --freq 868e6 --seconds 2
```

```matlab
>> addpath matlab
>> [x, meta] = fishball.readSigMF('air.sigmf-meta');
>> [db, f]   = fishball.spectrum(x, meta.SampleRate, 'FullScale', meta.FullScale);
>> plot((meta.CenterFrequency + f)/1e6, db); grid on
```

`readSigMF` reads exactly what `tools/sigmf-capture.py` writes, full scale
included, so a level measured here means the same as one in
[measured-performance.md](measured-performance.md). Verified against numpy on a
15 000 000-sample capture: same count, same first sample, same rms to six
decimals, same peak.

---

## Streaming, and letting the fabric help

MATLAB can keep up with a live audio stream from this board, but only just —
and the way to make it comfortable is to stop doing the work in MATLAB.

Profiled at 2.4 MS/s with 0.2 s frames:

```
read        179.7 ms     <- 90 % of a 200 ms budget
all the DSP  11.3 ms
```

The read is not slow; it is *real-time limited*, because 0.2 s of signal takes
0.2 s to arrive. But the processing after it means each turn costs ~212 ms and
yields 200 ms of audio, and the sound card starves at about 6 % **for ever**.
Buffering delays that and does not remove it.

The fix is the **÷8 decimating filter in the FPGA fabric**. Engaging it means
the host reads 288 kHz instead of 2.304 MHz: eight times less data and no
decimation stage in MATLAB.

```
3.2 s of audio    3.39 s of wall clock  ->  2.64 s
40 s of listening    113 underruns      ->  0
```

There is no "filter on" attribute. Writing the ADC device's
`sampling_frequency` to one eighth of the converter rate *is* what drives
`GP_CONTROL` bit 0 and the bypass mux. **And it is only safe on both receivers
because of patch `0021`** — on upstream wiring, or a `STOCK_RX_FILTER=1` build,
engaging it aliases RX2 by about 70 dB. See
[both-receive-channels.md](both-receive-channels.md).

---

## Transmitting

Only example 03 transmits, and `fishball.safeTransmit` will not start without
`PadDb`. This board reaches about **+19 dBm** and its own receive input is rated
**+2.5 dBm**, so a loopback needs **at least 20 dB** between them. Nothing on
the board can sense what is on the transmit port — there is no coupler and no
detector — so the number has to come from you.

It reads the applied attenuation back **off the chip** after the buffer starts
and stops the transmitter if it disagrees by more than 0.5 dB, because patch
`0005` restores a cached attenuation when a buffer opens. Verified: asked for
−50, −30, −20 dB, chip reported −50.00, −30.00, −20.00, and −89.75 dB before
and after.

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
directions, so on that path RX2 and TX2 do not exist. That is the whole reason
these exist.

Parameters are grouped in the dialog and named the way the rest of the SDR
world names them — `BasebandSampleRate`, `RFBandwidth`, `RFPort`, `GainSource`,
`SamplesPerFrame` — so what you know from `sdrrx` or from a datasheet
transfers.

> ### Set "Simulate using" to Interpreted execution
>
> Not a preference. These blocks reach the radio through `iio_readdev` and
> `iio_attr`, which means `system()`, and `system()` has no generated
> equivalent. The default is **Code generation**, and with it the model fails
> to compile with `An error occurred in the block '...' during compile`, which
> names nothing. The generators in example 06 set it for you.

### The model can drive the radio

`ControlPorts` turns the levers into **input ports** — `'tune'` gives you
frequency, `'full'` adds gain and bandwidth, `'all'` adds a second gain, the
gain mode and the RF port. A `NaN` on a port means *leave this alone*, so a
model can drive one lever without wiring a constant to every port, and a value
is pushed only **when it changes** — each change is an `iio_attr` round trip of
roughly 10–30 ms against a 14 ms frame at 288 kHz.

`examples/matlab/06-simulink/fishball_scanner.slx` is the worked example: a
staircase walks the oscillator across 88–108 MHz in 70 looks of 288 kHz.
Verified against the chip — a four-step sweep from 89.0 MHz left the local
oscillator at 89 863 998 Hz against a commanded 89 864 000.

### Two levers this board refuses

Both are real AD9361 attributes, both are offered, and both are rejected by
this firmware with `Invalid argument (22)`:

- **`RFPort`** — only `A_BALANCED` is accepted, although
  `rf_port_select_available` advertises twelve including `TX_MONITOR1/2`.
  Refused from an idle ENSM state as readily as from a running one.
- **`EnableRxFIR`** — nothing to enable until coefficients are loaded through
  `filter_fir_config`. Design taps with `firmware/scripts/gen_fir_coe.m`.

The three tracking levers — quadrature, RF DC and baseband DC — do apply.

The block **warns once per attribute** when the radio refuses a write, with the
chip's own message. It used to send every write to `/dev/null`, which made a
refused setting look exactly like an applied one.

---

## Troubleshooting

| | |
|---|---|
| `No board answered on fishball.local…` | Not on the network, or elsewhere. `BOARD=192.168.2.1 matlab` on the USB cable, or `./devkit status` |
| MATLAB offers to update the firmware | **Refuse.** See the top of this page |
| Connection dies with `data type supplied is incorrect for parameter {1}` | The `fw_version` bug above. Re-run `fishball-identity` on the board |
| `already owned by a block, block dialog, or System object` | A **failed** setup leaves the radio held for the rest of the session, so this is usually the ghost of an earlier error. `clear all` |
| `-16 EBUSY` | A killed client left a session holding the DMA **on the board**. No host-side action clears it; `killall iiod` over ssh does |
| Everything reads near zero | Your antenna is probably on the other port. `'RxChannel', 2` |
| Audio underruns while listening | See [streaming](#streaming-and-letting-the-fabric-help) |
| A licence error naming a toolbox | The examples degrade with a message naming it. The SigMF path needs only Communications Toolbox |

---

## Where things are

| | |
|---|---|
| [`matlab/+fishball/`](../matlab/+fishball/) | the package: `connect`, `capture2`, `spectrum`, `phase`, `evm`, `qam`, `safeTransmit`, `readSigMF`, `doctor` |
| [`examples/matlab/`](../examples/matlab/) | six examples, receive-first; 06 is Simulink |
| [`tools/matlab.sh`](../tools/matlab.sh) | what `./devkit matlab` runs |
