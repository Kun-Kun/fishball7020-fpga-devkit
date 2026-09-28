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

## Status

The build works and is Vitis-free. It is **not** wired into `build_all.sh`, so
the firmware build is unchanged and there is nothing to roll back. What remains
before it can be: the staleness check against `system.hwh`, booting an FSBL
built this way from a **second SD card**, and only then flipping the default.
