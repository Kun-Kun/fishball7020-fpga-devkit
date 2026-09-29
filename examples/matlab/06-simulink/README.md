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

## The custom block, which is the point

The model is built with **`fishball.RxSource`**, a MATLAB System block in this
repository, not the stock ADALM-Pluto block. Three things follow:

| | stock Pluto block | `fishball.RxSource` |
|---|---|---|
| receivers | RX1 only — `ChannelMapping must be equal to 1` | **RX1, RX2 or both**, sample-aligned |
| FPGA ÷8 decimator | no access | `Decimation` 1 or 8 — eight times less data over the network |
| telemetry | none | second output: `[rssi1, rssi2, AD9361 °C, applied gain]` |

`make_fishball_rx_model('Source','pluto')` builds the stock version instead, if
you want to compare.

> ### It must be set to "Interpreted execution"
>
> ```matlab
> set_param(blk, 'SimulateUsing', 'Interpreted execution')
> ```
>
> The generator does this for you. The default is **Code generation**, and this
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
