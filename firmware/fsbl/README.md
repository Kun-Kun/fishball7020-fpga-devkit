# Building the FSBL without Vitis

## If none of those words mean anything yet

**Start here. The rest of this page assumes you have read this bit.**

When you power this board on, three pieces of software run in order, each one
loading the next:

| | | |
|---|---|---|
| 1 | **FSBL** — First Stage Boot Loader | ~90 KB. The very first code the ARM cores run. Its job is to wake up the DDR memory chips and load the next thing. Nothing else can run before memory works. |
| 2 | **U-Boot** | Finds the SD card, loads Linux into that memory, hands over. |
| 3 | **Linux** | What you actually log in to. |

All three are packed into one file, `BOOT.bin`, which sits on the SD card.

The FSBL is the awkward one. Waking up DDR needs settings **specific to this
board's circuit-board layout** — trace lengths change the timing — and those
settings come out of the FPGA design as a file called `ps7_init.c`. Compiling
it used to need **Vitis**, AMD's ~30 GB software IDE. That was the *only* thing
Vitis was here for, and it is why this project used to tell you to install it.

It no longer does. AMD publishes the FSBL's source code in a repository called
[**embeddedsw**](https://github.com/Xilinx/embeddedsw), and it can be compiled
with an ordinary free compiler. Two terms you will meet below:

- **cross-compiler** — a compiler that runs on your PC but produces code for a
  different processor. `gcc-arm-none-eabi` is one: `arm` is the target, and
  `none-eabi` means "no operating system", which is exactly the situation the
  FSBL is in.
- **BSP** (Board Support Package) — the drivers the FSBL needs in order to talk
  to the board's UART, SD controller and so on. It is compiled from embeddedsw
  too, but a handful of its files are *generated* from the FPGA design, and
  those are the ones committed in [`generated/`](generated/).

**What this means for you:** `./devkit build` needs Vivado (for the FPGA) but no
longer needs Vitis. If you only want to change Linux, you need neither — see
[building without Vivado](../../docs/building-without-vivado.md).

---


The FSBL — the First Stage Boot Loader, the first code the ARM cores run — used
to be compiled by `xsct`, which is part of Vitis and which AMD has deprecated.
That single dependency was the reason
[`building-without-vivado.md`](../../docs/building-without-vivado.md) had to say
*"this skips Vivado, it does **not** skip Vitis"*, and the reason
`tools/container/Containerfile` carried Xvfb, GTK3, WebKit and the rest of the
SWT stack — Vitis is Eclipse-based.

This directory is what replaced it, as asked for in
[issue #7](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/7).
**The `xsct` path was deleted on 2026-09-28**, along with those packages, once a
board had booted an FSBL built this way.

## What `xsct` used to do

This is why `generated/` exists, so it is worth keeping. Three jobs, and only
one of them was hard:

1. **Copies the FSBL sources in.** They are AMD's public
   [`embeddedsw`](https://github.com/Xilinx/embeddedsw) `lib/sw_apps/zynq_fsbl`,
   verbatim — measured, see below.
2. **Generates the board support package** and compiles it into `libxil.a`,
   `libxilffs.a`, `librsa.a`. The *sources* are embeddedsw too; what is generated
   is a small set of files describing **this** hardware design.
3. **Wrote an Eclipse makefile** and ran it. embeddedsw ships its own Makefiles
   and xsct shelled out to them, so this part was always Vitis-free.

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

## Building it

```bash
make -C firmware/fsbl            # stage, build the BSP, link fsbl.elf
make -C firmware/fsbl compare    # diff against the xsct-built reference
```

Needs `gcc-arm-none-eabi` and `libnewlib-arm-none-eabi`, and nothing else from
Xilinx. `stage.sh` assembles a throwaway tree from embeddedsw + `generated/` +
`ps7_init.c` extracted from the XSA; the BSP is then built by **embeddedsw's own
Makefiles**, which is what `xsct` shells out to anyway.

## How it was validated

**First, with Vitis's own compiler, the build reproduces the FSBL byte for byte:**

```
make -C firmware/fsbl CROSS=$VITIS_CROSS compare
  ours   ba1914df986d5e77d5f6d574f475e282  98312 bytes
  vitis  ba1914df986d5e77d5f6d574f475e282  98312 bytes
  IDENTICAL
```

That is the loadable image — what `bootgen` puts in `BOOT.bin` — so the source
manifest, the flags, the archive contents, the link order and all 21 generated
files are provably right, with **zero** codegen variables. Doing this first meant
the toolchain swap below was the only remaining unknown.

**Then the distro toolchain**, GCC 10.3.1 against Vitis's 11.2.0:

| | distro 10.3 | Vitis 11.2 | Δ |
|---|---|---|---|
| `.text` | 85 724 | 85 532 | **+192** |
| `.data` | 11 660 | 11 656 | +4 |
| `.bss` | 75 476 | 75 480 | −4 |
| total | 172 860 | 172 668 | +192 |
| **OCM headroom** (of 196 608) | **23 748** | 23 940 | −192 |
| loadable image | 98 316 | 98 312 | +4 |
| build warnings | **0** | — | — |

`.rodata`, `.mmu_tbl`, `.heap`, `.stack` and `.handoff` are identical in size.
The entire +192 is newlib's `atexit` / `__register_exitproc` / `register_fini`
machinery, which GCC 10's crt pulls in and 11's did not — dead weight in an FSBL
that never returns, but harmless. The other symbols that appear "new"
(`create_chain.isra.0` and friends) are GCC's IPA-clone naming, not new
functions.

Both toolchains resolve the same multilib for our flags,
`thumb/v7-a+fp/hard` — worth checking, because a newlib without the hard-float
multilib fails at link with an obscure "uses VFP register arguments".

## It is the only path

`./devkit build` uses it, and there is no longer an alternative — `--fsbl` was
removed and tells you so if you pass it.

```bash
./devkit setup                         # fetches embeddedsw: sparse, ~75 MB, pinned by SHA
sudo apt install gcc-arm-none-eabi libnewlib-arm-none-eabi
./devkit build                         # no Vitis anywhere in it
```

The byte-equivalence check against Vitis survives, because it needs only Vitis's
*compiler* and not `xsct`. It is opt-in and local: `GOLDEN` points at a reference
tree on your own machine, not at anything in this repo.

```bash
make -C firmware/fsbl CROSS=$VITIS_CROSS compare
```

`./devkit doctor` checks all of that: a missing `arm-none-eabi-gcc`, or one
without the hard-float multilib, is a failure. It no longer looks for Vitis, or
for a display.

**The staleness guard runs before the FSBL compiles.** `hwcheck.py` compares the
XSA's `system.hwh` against the committed headers semantically — a plain hash is
useless, because that file carries a `TIMESTAMP` that changes on every Vivado
run. A moved, renamed, added or removed peripheral fails the build, with the
address printed. It has been tested by moving and removing entries, not just by
passing.

## A board has booted it

2026-09-28. This was the last gap, and it is closed. The test was run on a
second SD card written by [`tools/make-sd-card.sh`](../../tools/make-sd-card.sh),
with the board's own card removed and untouched.

**The experiment had one variable.** The same bitstream and the same `u-boot`
were packaged twice, once with the xsct FSBL and once with the embeddedsw one.
The xsct package came out byte-identical to `firmware/output/BOOT.bin`, which
proves the packaging step was faithful; the two images then differ only in
bytes 53–104 204, the boot header and the FSBL partition. Everything after that
— 2.79 MB of bitstream and U-Boot — is bit-identical.

What the board did with the embeddedsw image:

| | |
|---|---|
| DDR brought up | U-Boot reports `DRAM: ECC disabled 1 GiB` — this is `ps7_init.c` doing its job |
| Card read | `Capacity: 29.1 GiB`, the test card, not the board's own |
| Bitstream loaded | `cf-ad9361-dds-core-lpc` and `cf-ad9361-lpc` enumerate — both are **PL** fabric IP, so they exist only if the FSBL programmed the PL |
| Handoff | `U-Boot PlutoSDR`, then `Starting kernel ...` |
| Linux | 5.15.0 #16 to a `fishball login:` prompt |
| Errors | none in the boot log |
| Radio | `ad9361-phy`, `xadc` and both DMA cores present |

So `--fsbl=xsct` stopped being a safety net, and was deleted the same day.

## Nothing from AMD is required any more

`bootgen`, which packages `BOOT.bin`, was the last AMD binary in the build, and
the only reason Vivado had to be *installed* for an `--xsa` build that never ran
it. AMD publishes its source under Apache-2.0, so `./devkit setup` clones it
(~8 MB, pinned by SHA) and builds it — about five seconds against system
OpenSSL. That build is used always, not just when Vivado is absent, so what
comes out of packaging does not depend on which AMD tools happen to be
installed.

Checked the only way worth checking:

| | |
|---|---|
| Our bootgen vs Vivado's, same inputs | **byte-identical** `BOOT.bin` |
| That image | the one a board booted on 2026-09-28 |
| `ldd` on our binary | system OpenSSL/libstdc++ only, nothing under `/tools/Xilinx` |
| Rebuilt in a container with `/tools/Xilinx` **not mounted** | same checksum |
| Whole build with `XILINX_DIR=/nonexistent`, no `$DISPLAY`, nothing AMD on `PATH` | same checksum |

Vivado is now needed for exactly one thing — synthesising the bitstream — and
`--xsa` skips even that.

## Still to do

Nothing blocking. Hosted CI still cannot build the FSBL end to end, because it
needs an XSA and none is tracked; now that both embeddedsw and bootgen build
from source in seconds, the only missing piece is deciding where CI should get
a hardware platform from.
