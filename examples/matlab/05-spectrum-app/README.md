# 05 — a live spectrum window

A live spectrum you can drive: type a centre frequency, a span and a gain, pick
a receiver, toggle max-hold. The numbers under the plot are the same ones
`fishball.spectrum` computes for the other examples, so what you see here and
what you measure there agree.

Receive only. Nothing here transmits. Close the window to stop it.

```bash
# run from: the repo root, in a SHELL
./devkit matlab shell
```

```matlab
>> % run from: the MATLAB prompt (./devkit matlab shell puts the example on the path)
>> spectrum_app                                                  % RX1, 900 MHz, 3 MS/s, gain 45
>> spectrum_app('RxChannel', 2, 'CenterFrequency', 90.4e6)
>> spectrum_app('RxChannel', 2, 'CenterFrequency', 868e6, 'SampleRate', 5e6)
```

## Reading it

A broadcast FM station should look about **200 kHz wide** and stand tens of dB
above a *flat* floor. On RX2 at 90.4 MHz, 3 MSPS span, gain 45: peak
−54.3 dBFS, floor about −82 dBFS, flat right across the span. If your floor
slopes or humps, you are looking at a filter, not at noise.

**The floor is the median bin**, not the minimum. A minimum is one unlucky bin
and jumps between frames; the median is the level most of the band sits at,
which is what "the noise floor" means.

**Max-hold** catches something that is only there sometimes: a remote control,
a doorbell, a car key. Turn it on and leave it while you press the thing.

## What it does that a simple spectrum display does not

- **It sets the analogue filter to the span.** The AD9361's `rf_bandwidth` is
  whatever the last program left it at. Leave it and you see the *filter's*
  shape rather than the band's: a narrow peak with wide skirts that looks like a
  signal and is not.
- **It tells you when the converter is clipping.** A clipped ADC produces a
  spectrum that looks like a big strong signal and is mostly the clipping. The
  info line goes red and says `*** OVERLOAD: lower the gain ***`.
- **It rebuilds the receiver on every control change.** A System object does not
  accept a new setting while it is running; changing one **silently does
  nothing** (pyadi-iio has the same trap, fixed there with
  `rx_destroy_buffer()`).

## Both receivers

`'RxChannel', 2` goes through `fishball.capture2`, because `sdrrx` cannot reach
RX2 (see [example 01](../01-hello-board/)). RX1 keeps an `sdrrx` object open
between frames, which is faster; RX2 captures per frame.

## Why this is a function and not a `.mlapp`

App Designer stores an app as a binary file, and a binary in a repository
cannot be reviewed, diffed or merged. This repository ships generated artefacts
with the code that generates them. A `uifigure` built in code is a few dozen
readable lines.

## Testing it from a script

```matlab
>> % run from: the MATLAB prompt
>> spectrum_app('Frames', 6, 'Visible', false)
```

This runs a fixed number of refreshes with no window and returns, so a script
or CI can check the app. A window that runs until closed cannot be checked.
