# Building the FSBL without Vitis

The FSBL — the First Stage Boot Loader, the first code the ARM cores run — is
today compiled by `xsct`, which is part of Vitis and which AMD has deprecated.
That single dependency is the reason
[`building-without-vivado.md`](../../docs/building-without-vivado.md) has to say
*"this skips Vivado, it does **not** skip Vitis"*, and the reason
`tools/container/Containerfile` installs Xvfb, GTK2, GTK3, WebKit and the rest of
the SWT stack — Vitis is Eclipse-based.

This directory is the groundwork for removing it, as asked for in
[issue #7](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/7).

## What `xsct` actually does

Three jobs, and only one of them is hard:

1. **Copies the FSBL sources in.** They are AMD's public
   [`embeddedsw`](https://github.com/Xilinx/embeddedsw) `lib/sw_apps/zynq_fsbl`,
   verbatim — measured, see below.
2. **Generates the board support package** and compiles it into `libxil.a`,
   `libxilffs.a`, `librsa.a`. The *sources* are embeddedsw too; what is generated
   is a small set of files describing **this** hardware design.
3. **Writes an Eclipse makefile** and runs it. embeddedsw ships its own Makefiles
   and xsct shells out to them, so this part is already Vitis-free.

So the only thing that genuinely cannot be fetched from embeddedsw is (2)'s
generated set — 21 files, which is what lives in `generated/`.

## Why these files are committed

Because they describe one fixed hardware design and regenerating them needs the
very tool we are removing. Committing them is a deliberate trade: it buys a build
that needs no Vitis, at the cost of an artefact that can go stale.

**Stale means wrong, and wrong here is not always loud.** The `config/*_g.c`
tables key on `XPAR_<INSTANCE>_*` macro *names*, so a renamed peripheral is a
compile error — fine. But `xparameters.h` also carries addresses and six
`FILE_SYSTEM_*` lines that `xilffs` compiles against, and a wrong address is a
board that does not boot, with nothing to read. That is why a staleness check
belongs in the build rather than in a comment, and why
[`provenance.txt`](provenance.txt) records the XSA these were taken from.

## How much of this was verified rather than assumed

Everything in `generated/` is there because it was **shown** to have no
counterpart in embeddedsw. 229 files were compared byte-for-byte against
`xilinx_v2022.2`:

| | identical | generated |
|---|---|---|
| FSBL app sources | 23 of 27 | `ps7_init.{c,h}`, `ps7_parameters.xml` (from the XSA), `Xilinx.spec` |
| standalone BSP | 89 of 89 | `bspconfig.h`, `inbyte.c`, `outbyte.c`, `config.make` |
| 18 drivers | 117 | exactly 15 `*_g.c` |
| xilffs | 4 | — |

`lscript.ld` was expected to be generated and is not — it matches embeddedsw's
copy exactly, so it is fetched rather than committed. Checking was cheaper than
assuming.

## Status

Groundwork only. The build still runs `xsct`; nothing here is wired into
`build_all.sh` yet. The next step is a Makefile that stages embeddedsw plus these
files and builds the BSP with embeddedsw's own Makefiles, verified by producing
an `fsbl.elf` whose loadable image matches the one Vitis produces today.
