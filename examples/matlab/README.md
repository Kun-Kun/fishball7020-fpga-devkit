# MATLAB examples

Five projects, receive-first, each one a thing you can run in a minute rather
than a framework to learn. They exist because this board is a *two-channel*
AD9361 that software mostly mistakes for a one-channel Pluto, and the places
where that assumption leaks are exactly where a measurement goes quietly wrong.

**Jargon, once.** *IQ* is a complex sample: two numbers per instant, which is
what lets a radio tell a signal above the tuned frequency from one below it.
*dBFS* is decibels relative to the converter's full scale — a level, not a
power, and never dBm; nothing in this repository is calibrated to absolute
power. *EVM* is how far a received symbol lands from where it should, as a
percentage. *Coherence* is how much two receivers are hearing the same thing,
0 to 1.

| | What it teaches | Transmits? |
|---|---|---|
| [**01 — hello board**](01-hello-board/) | Connect, identify, capture, plot. Where the ±2047 full-scale trap is taught | no |
| [**02 — FM receiver**](02-fm-receiver/) | Wideband FM to audio, why you cannot ask this chip for 250 kS/s, and letting the fabric filter do the work | no |
| [**03 — modulated link**](03-modulated-link/) | QPSK/QAM through a loopback: constellation and EVM | **yes** |
| [**04 — two coherent receivers**](04-coherent-rx/) | RX1 against RX2: phase and coherence. The thing a Pluto cannot do | no |
| [**05 — spectrum app**](05-spectrum-app/) | A live window: tune, span, gain, max-hold, either receiver | no |

Start at 01 even if you know MATLAB. It is the one that sets up the habit the
others rely on — that a level is meaningless until you know what full scale is.

## Before you start

**Two kinds of code block below.** A `bash` block runs in your terminal. A block
whose lines start with `>>` runs at the **MATLAB prompt** — the `>>` is the
prompt, not something you type. Pasting MATLAB into bash gets you
`addpath: command not found`.


```bash
# run from: the repo root, in a SHELL - this starts MATLAB
matlab
```

```matlab
>> % run from: the MATLAB prompt, with the repo root as the current folder
>> addpath matlab
>> fishball.doctor
```

`fishball.doctor` checks the MATLAB side and the board in a few seconds, and
every check it makes is one that has already cost somebody time.

You need **Communications Toolbox**, and for live radio the **Communications
Toolbox Support Package for Analog Devices ADALM-Pluto**. Without the support
package you can still run everything offline against a capture — see
[the SigMF route](#no-support-package-no-problem).

> ### Never let MATLAB update your firmware
>
> The support package was tested against Pluto firmware `v0.39`, sees this
> board's version, and offers to "switch the firmware version" through the
> Hardware Setup App. **Do not.** That image is for an **ADALM-Pluto** — a
> Zynq-**7010** with an AD**9363**. This board is a Zynq-**7020** with an
> AD**9361**, a different FPGA and a different transceiver, and on the common
> variant a power amplifier the Pluto does not have.
>
> `fishball.connect` suppresses that warning and prints the safe half of it
> instead, once per session.

## No support package, no problem

Every analysis here runs on a capture file, so you can do all of it with base
MATLAB plus Communications Toolbox:

```bash
# run from: the repo root - make a capture with the Python tool
./tools/sigmf-capture.py record air --rate 3e6 --freq 868e6 --seconds 2
```

```matlab
>> % run from: the MATLAB prompt
>> addpath matlab
>> [x, meta] = fishball.readSigMF('air.sigmf-meta');
>> [db, f]   = fishball.spectrum(x, meta.SampleRate, 'FullScale', meta.FullScale);
>> plot((meta.CenterFrequency + f)/1e6, db); grid on
>> xlabel('MHz'); ylabel('dBFS')
```

`readSigMF` reads exactly what `tools/sigmf-capture.py` writes, full scale
included, so the number on your axis means the same thing as the number in
`docs/measured-performance.md`.

## Three things that will bite you

**Full scale is ±2047, not ±32768.** The converters are 12-bit sign-extended
into `int16`. Divide by 32768 and every absolute level is **24.09 dB** low —
uniformly, so nothing looks wrong. Ratios like SNR and EVM are unaffected,
which is why this survives review. Worse, MATLAB is inconsistent with itself:
`sdrrx` with `OutputDataType` `int16` gives raw counts (±2047) while `double`
and `single` give those divided by **2048** (±1.0). `fishball.spectrum` takes
`FullScale` for exactly this reason.

**Changing a property on a running object does nothing.** Setting `.Gain` on a
locked System object does not reach the chip — measured, six identical frames
across a 50 dB change. `release()` and build a new one, or call
`fishball.connect` again. pyadi-iio has the same trap, where the fix is
`rx_destroy_buffer()`.

**`sdrrx` cannot reach the second receiver.** `ChannelMapping` must be a scalar
and must be `1`; the support package is written for a 1R1T radio. Both
receivers *are* reachable — `cf-ad9361-lpc` has four scan channels — just not
through that object. Use `fishball.capture2`, which is what example 04 does.

## Transmitting

Only example 03 transmits, and it will not start without you saying a pad is
fitted. This board reaches about **+19 dBm** and its own receive input is rated
**+2.5 dBm**, so a loopback needs **at least 20 dB** of attenuation between
them. Read [`docs/transmitter-safety.md`](../../docs/transmitter-safety.md)
before it radiates anything.
