# 01 — hello board

```matlab
% run from: the repo root
addpath matlab examples/matlab/01-hello-board
hello_board
hello_board('CenterFrequency', 868e6)     % wherever your antenna is useful
```

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
| Everything reads near zero | Your antenna is on the other port. This board has two receivers; `hello_board` uses RX1. Try `fishball.capture2` (example 04) to see both at once |
