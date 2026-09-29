# 01 — hello board

```bash
# run from: the repo root, in a SHELL
matlab
```

```matlab
>> % run at the MATLAB prompt, with the repo root as the current folder
>> addpath matlab examples/matlab/01-hello-board
>> hello_board
```

Or skip the `addpath` entirely:

```bash
# run from: the repo root, in a SHELL
./devkit matlab hello
```

**These are alternatives, not a sequence** — each line below is one way to call
it, so run the one you want rather than all of them:

```matlab
>> hello_board                              % RX1, 868 MHz
>> hello_board('Channel', 2)                % RX2 - see below, this is the interesting one
>> hello_board('CenterFrequency', 100e6)    % wherever your antenna is useful
>> hello_board('Plot', false)               % numbers only
```

Repeated calls reuse one figure window rather than stacking a new one each time.

Receive only. Nothing here transmits.

This is the example that proves the chain works end to end — MATLAB, the
support package, the network, the board, the converters — and it is deliberately
the one that teaches the level trap, because every number you print afterwards
depends on getting it right.

## What it prints, and what to look at

**The board's identity.** `hw_model` should contain `Z7020` and `AD9361`. If it
says `Z7010` you have half the fabric; if it says `AD9363` — the chip in an
ADALM-PLUTO — the radio is specified to 325 MHz–3.8 GHz with 20 MHz of channel
bandwidth rather than 70 MHz–6 GHz and 56 MHz.

`fw_version` is the release and `fw_build` the full `git describe`. They are
two attributes rather than one because MATLAB's support package cannot cope
with a describe string in `fw_version` — see
[`docs/matlab.md`](../../../docs/matlab.md).

**The full-scale comparison.** The same peak printed twice:

```
  peak, against 2047  (right) :  -43.28 dBFS
  peak, against 32768 (wrong) :  -67.36 dBFS   <- 24.09 dB low
```

That 24.09 dB is `20*log10(32768/2047)`, and it is the single most common way
to publish a wrong number from this board. It is uniform, so a spectrum keeps
its shape, every SNR is unchanged and nothing looks broken. Only absolute
levels move, and they all move together.

## The two receivers, and why `Channel` matters

This board is **2R2T** — two complete receivers inside one AD9361, sharing one
local oscillator and one sample clock. An ADALM-PLUTO is 1R1T, and MATLAB's
support package is written for that: ask `sdrrx` for `ChannelMapping` 2 and it
refuses outright with *"ChannelMapping must be equal to 1"*.

So `hello_board('Channel', 2)` takes a different route, and says so when it
does. RX2 is reached through `iio_readdev`, which has no such opinion, wrapped
up as `fishball.capture2`. Same board, same samples, different door.

Run both and the difference should be obvious if your antenna is on one port
and not the other. On the board this was written against — a 20 dB loopback pad
on RX1, an 868 MHz antenna on RX2:

```
== capture, RX1 ==      peak |sample| = 12.6     strongest bin -73.42 dBFS
== capture, RX2 ==      peak |sample| = 422.6    strongest bin -50.59 dBFS @ 866.66 MHz
```

Example 04 uses both at once, which is the thing a one-channel radio cannot do.

**The spectrum.** The noise floor is the *median* bin, not the minimum — a
minimum is one unlucky bin and moves around. On a quiet band with an antenna
fitted you should see a floor near −90 dBFS and whatever is actually on the
air above it.

## If it does not work

| | |
|---|---|
| `No board answered on fishball.local...` | The board is not on the network, or it is on a different address. `BOARD=192.168.2.1 matlab` if you are on the USB cable, or run `./devkit status` |
| MATLAB offers to update the firmware | **Refuse.** See the warning in [the examples README](../README.md) |
| `already owned by a block...` | A failed setup earlier in the same session still holds the radio. `clear all` |
| Everything reads near zero | Your antenna is probably on the other port. Try `hello_board('Channel', 2)` |
