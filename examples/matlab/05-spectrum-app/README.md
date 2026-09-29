# 05 — a live spectrum window

```bash
# run from: the repo root, in a SHELL
./devkit matlab shell
```

```matlab
>> spectrum_app
>> spectrum_app('RxChannel', 2, 'CenterFrequency', 90.4e6)
>> spectrum_app('RxChannel', 2, 'CenterFrequency', 868e6, 'SampleRate', 5e6)
```

Receive only. Nothing here transmits. Close the window to stop it.

Type a centre frequency, a span and a gain; pick a receiver; toggle max-hold.
The numbers under the plot are the same ones `fishball.spectrum` computes for
the other examples, so what you see here and what you measure there agree.

## Why this is a function and not a `.mlapp`

App Designer stores an app as a binary file. That works, and a binary in a
repository cannot be reviewed, diffed or merged — and this repository already
takes the view that a generated artefact ships with the thing that generates
it. A `uifigure` built in code is a few dozen readable lines.

## Two things it does that a naive spectrum display does not

**It sets the analogue filter to the span.** The AD9361's `rf_bandwidth` is
whatever the last program left it at. Leave it and the picture you get is the
*filter's* shape rather than the band's — a narrow peak with wide skirts that
looks like a signal and is not. The first version of this app did exactly that
and drew a convincing spike with 500 kHz skirts, which was a 400 kHz filter left
over from another test.

**It tells you when the converter is clipping.** A clipped ADC produces a
spectrum that looks like a big strong signal and is mostly the clipping. The
info line goes red and says `*** OVERLOAD: lower the gain ***`.

## The floor is the median bin

Not the minimum. A minimum is one unlucky bin and jumps around between frames;
the median is the level most of the band is actually sitting at, which is what
you mean when you say "the noise floor".

## Reading it

A broadcast FM station should look about **200 kHz wide** and stand tens of dB
above a *flat* floor. Measured here on RX2 at 90.4 MHz, 3 MSPS span, gain 45:
peak −54.3 dBFS, floor about −82 dBFS, and the floor flat right across the span.
If your floor slopes or humps, you are looking at a filter, not at noise.

Max-hold is how you catch something that is only there sometimes — a remote
control, a doorbell, a car key. Turn it on and leave it while you press the
thing.

## Both receivers

`'RxChannel', 2` goes through `fishball.capture2`, because `sdrrx` cannot reach
RX2 — see [example 01](../01-hello-board/). RX1 keeps a `sdrrx` object open
between frames, which is faster; RX2 captures per frame.

Changing any control throws the receiver away and rebuilds it. That is not
laziness: a System object will not accept a new setting while it is running and
changing one **silently does nothing**, which is the same trap pyadi-iio has,
where the fix is `rx_destroy_buffer()`.

## Testing a window

`spectrum_app('Frames', 6, 'Visible', false)` runs a fixed number of refreshes
with no window and returns. A window that runs until closed cannot be checked by
a script, and an example nobody can check is an example that quietly rots.
