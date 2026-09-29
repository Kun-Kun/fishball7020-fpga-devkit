# 06 — Simulink

```bash
# run from: the repo root, in a SHELL
./devkit matlab shell
```

```matlab
>> open_system('examples/matlab/06-simulink/fishball_rx.slx')
```

Receive only. Nothing here transmits. Press run; a spectrum window opens.

To rebuild it, or point it somewhere else:

```matlab
>> addpath examples/matlab/06-simulink
>> make_fishball_rx_model('CenterFrequency', 100.1e6, 'Open', true)
```

## Two files, and why

| | |
|---|---|
| `fishball_rx.slx` | the model. Committed so it opens without you running anything |
| `make_fishball_rx_model.m` | the thing that builds it. Committed so you can **read** it |

An `.slx` is a binary. It works, and in version control it cannot be reviewed,
diffed or merged — you cannot see what changed between two versions, which is
most of the point of keeping it. So both are here, which is the same
arrangement the rest of this repository uses for generated things
(`docs/img/make_*_svg.py`, `docs/course/make_print_html.py`).

If you change the model in Simulink and save it, the two disagree. Change the
generator and re-run it instead, or accept that the `.m` is then stale.

## RX1 only, and that is not a choice

The Simulink block is the same support package as `sdrrx`, with the same limit:
`ChannelMapping must be equal to 1`. There is **no Simulink path to RX2** on
this board. If you need the second receiver — which is the interesting one here,
see [example 04](../04-coherent-rx/) — that is MATLAB and `fishball.capture2`.

## The default is a station

`90.4e6` and 2.304 MSPS, because that is a real FM station on the board this was
written against and a model that shows noise on first run teaches nothing. Find
yours with `fm_stations` ([example 02](../02-fm-receiver/)) and rebuild.

2.304 MSPS is chosen so the arithmetic downstream is exact and it clears the
AD9361's 2.083 MSPS floor — see example 02 for why that floor matters.

## Built with

MATLAB **R2026a** and the Communications Toolbox Support Package for ADALM-Pluto
**26.1.7**. An `.slx` records the release that wrote it and older MATLABs will
refuse to open it; the generator will rebuild it for any release that has the
support package.

Verified: builds, and simulates against the board (0.5 s of simulation, most of
the 32 s being the support package's connection setup).

One implementation note worth keeping, because it costs an afternoon otherwise:
the library block's **name contains a real newline** — Simulink names it across
two lines and that line break is part of the name. `add_block` therefore needs
`sprintf('plutoradiolib/ADALM-Pluto Radio\nReceiver')`; the same string in plain
single quotes is the two characters backslash-n and matches nothing.
