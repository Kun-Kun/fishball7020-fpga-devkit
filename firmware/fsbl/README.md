# firmware/fsbl: the first-stage boot loader, built without Vitis

This directory builds the board's **FSBL** (First Stage Boot Loader) from AMD's
public [embeddedsw](https://github.com/Xilinx/embeddedsw) sources with an
ordinary free compiler. `./devkit build` uses it; no Vitis is involved, and
nothing else from AMD is needed to compile it.

## If none of those words mean anything yet

When you power this board on, three pieces of software run in order, each one
loading the next:

| | | |
|---|---|---|
| 1 | **FSBL**, First Stage Boot Loader | ~90 KB. The very first code the ARM cores run. It wakes up the DDR memory chips and loads the next stage. Nothing else can run before memory works. |
| 2 | **U-Boot** | Finds the SD card, loads Linux into that memory, hands over. |
| 3 | **Linux** | What you log in to. |

All three are packed into one file, `BOOT.bin`, on the SD card.

Waking up DDR needs settings **specific to this board's circuit layout** (trace
lengths change the timing). Those settings come out of the FPGA design as a file
called `ps7_init.c`, inside the design's XSA (the exported hardware platform).
AMD's IDE, Vitis (~30 GB), can compile it, but so can this directory. Two terms
you will meet below:

- **cross-compiler**: a compiler that runs on your PC but produces code for a
  different processor. `gcc-arm-none-eabi` is one: `arm` is the target, and
  `none-eabi` means "no operating system", which is the FSBL's situation.
- **BSP** (Board Support Package): the drivers the FSBL needs to talk to the
  board's UART, SD controller and so on. It is compiled from embeddedsw too, but
  a handful of its files are *generated* from the FPGA design, and those are
  the ones committed in [`generated/`](generated/).

**What this means for you:** `./devkit build` needs Vivado (for the FPGA) but
not Vitis. If you only want to change Linux, you need neither: see
[building without Vivado](../../docs/building-without-vivado.md).

## Quick start

```bash
# run from: the repo root
sudo apt install gcc-arm-none-eabi libnewlib-arm-none-eabi
./devkit setup      # fetches embeddedsw: sparse, ~75 MB, pinned by SHA
./devkit build      # builds the FSBL as stage 2
```

On its own, after a build has produced an XSA:

```bash
# run from: the repo root
make -C firmware/fsbl            # stage, build the BSP, link fsbl.elf
```

`ESW=` and `XSA=` override where it finds embeddedsw
(default `firmware/src/embeddedsw`) and the hardware platform
(default `firmware/src/hdl/projects/pluto/system_top.xsa`).

`./devkit doctor` checks the compiler: a missing `arm-none-eabi-gcc`, or one
without the hard-float multilib, is a failure. `--fsbl` was removed from
`build_all.sh`, which says so if you pass it; there is no other FSBL path.

## What is in this directory

| | |
|---|---|
| `Makefile` | `all` (stage, BSP, `fsbl.elf`) and `compare` (against a Vitis-built reference) |
| `stage.sh` | assembles a throwaway build tree from embeddedsw + `generated/` + `ps7_init.c` from the XSA |
| `generated/` | the 21 BSP files generated from this hardware design, which have no counterpart in embeddedsw |
| `hwcheck.py` | the staleness guard: checks `generated/` against the XSA before the FSBL compiles |
| `provenance.txt` | which XSA and embeddedsw commit `generated/` was taken from, and how to redo it |
| `standalone-manifest.txt` | the embeddedsw standalone BSP files the build uses |

The BSP itself is built by **embeddedsw's own Makefiles**, the same ones Vitis's
`xsct` tool calls.

## Rules

- **Keep `generated/` in step with the FPGA design.** It describes one fixed
  hardware design, and regenerating it needs Vitis, so it is committed rather
  than generated at build time. A stale copy is not always a loud failure: the
  `config/*_g.c` tables key on `XPAR_<INSTANCE>_*` macro *names*, so a renamed
  peripheral is a compile error, but `xparameters.h` also carries addresses and
  six `FILE_SYSTEM_*` lines that `xilffs` compiles against, and a wrong address
  is a board that does not boot, with nothing to read.
- **`hwcheck.py` runs before the FSBL compiles** and compares the XSA's
  `system.hwh` with the committed headers semantically. A plain hash would be
  useless, because that file carries a `TIMESTAMP` that changes on every Vivado
  run. A moved, renamed, added or removed peripheral fails the build, with the
  address printed. It is tested by moving and removing entries.
- **Try a new FSBL on a second card.** A bad FSBL means a board that does not
  boot. [`tools/make-sd-card.sh`](../../tools/make-sd-card.sh) writes a spare
  card, so the board's own card stays untouched
  ([Option C2](../../docs/flashing.md#option-c2--a-second-card-when-you-do-not-want-to-risk-the-first)).

## Reference: what `generated/` holds, and why only that

What `xsct` did, in three jobs:

1. **Copied the FSBL sources in.** They are embeddedsw's
   `lib/sw_apps/zynq_fsbl`, verbatim.
2. **Generated the board support package** and compiled it into `libxil.a`,
   `libxilffs.a` and `librsa.a`. The *sources* are embeddedsw too; what is
   generated is a small set of files describing **this** hardware design.
3. **Wrote an Eclipse makefile** that calls embeddedsw's own Makefiles.

Only (2)'s generated set cannot be fetched from embeddedsw. 229 files were
compared byte for byte against `xilinx_v2022.2`:

| | identical | generated |
|---|---|---|
| FSBL app sources | 23 of 27 | `ps7_init.{c,h}`, `ps7_parameters.xml` (from the XSA), `Xilinx.spec` |
| standalone BSP | 89 of 89 | `bspconfig.h`, `inbyte.c`, `outbyte.c`, `config.make` |
| 18 drivers | 117 | exactly 15 `*_g.c` |
| xilffs | 4 | none |

`lscript.ld` matches embeddedsw's copy exactly, so it is fetched rather than
committed.

## Reference: the output matches Vitis

**With Vitis's own compiler, the build reproduces the Vitis FSBL byte for
byte.** `compare` checks the loadable image (what `bootgen` puts in `BOOT.bin`),
not the ELF, whose debug information carries absolute build paths:

```
# run from: the repo root. GOLDEN is a Vitis-built reference tree on your own
# machine (default ~/fishball-fsbl-golden-2022.2), not anything in this repo.
make -C firmware/fsbl CROSS=$VITIS_CROSS compare
  ours   ba1914df986d5e77d5f6d574f475e282  98312 bytes
  vitis  ba1914df986d5e77d5f6d574f475e282  98312 bytes
  IDENTICAL
```

So the source list, the flags, the archive contents, the link order and all 21
generated files are right, with no compiler difference involved. The check
needs only Vitis's *compiler*, not `xsct`, and is opt-in.

**With the distribution's toolchain** (GCC 10.3.1, against Vitis's 11.2.0):

| | distro 10.3 | Vitis 11.2 | Δ |
|---|---|---|---|
| `.text` | 85 724 | 85 532 | **+192** |
| `.data` | 11 660 | 11 656 | +4 |
| `.bss` | 75 476 | 75 480 | −4 |
| total | 172 860 | 172 668 | +192 |
| **OCM headroom** (of 196 608) | **23 748** | 23 940 | −192 |
| loadable image | 98 316 | 98 312 | +4 |
| build warnings | **0** | — | — |

OCM is the Zynq's 256 KB on-chip memory, where the FSBL runs. `.rodata`,
`.mmu_tbl`, `.heap`, `.stack` and `.handoff` are the same size. The whole +192
bytes is newlib's `atexit` / `__register_exitproc` / `register_fini` code, which
GCC 10's startup files pull in and 11's do not: unused in an FSBL that never
returns, and harmless. Symbols that look new (`create_chain.isra.0` and
similar) are GCC's names for cloned functions, not new functions.

Both toolchains resolve the same multilib for these flags,
`thumb/v7-a+fp/hard`. A newlib without the hard-float multilib fails at link
with "uses VFP register arguments".

## Reference: a board boots it

The embeddedsw FSBL has been booted on the board from a second SD card, with
the board's own card removed. The test changes one thing: the same bitstream
and the same U-Boot were packaged twice, once with the Vitis (`xsct`) FSBL and
once with this one. The `xsct` package is byte-identical to
`firmware/output/BOOT.bin`, so the packaging is faithful; the two images differ
only in bytes 53–104 204 (the boot header and the FSBL partition). The 2.79 MB
of bitstream and U-Boot after that are identical.

What the board does with the embeddedsw image:

| | |
|---|---|
| DDR brought up | U-Boot reports `DRAM: ECC disabled 1 GiB`: this is `ps7_init.c` doing its job |
| Card read | `Capacity: 29.1 GiB`, the test card, not the board's own |
| Bitstream loaded | `cf-ad9361-dds-core-lpc` and `cf-ad9361-lpc` enumerate; both are FPGA fabric IP, so they exist only if the FSBL programmed the FPGA |
| Handoff | `U-Boot PlutoSDR`, then `Starting kernel ...` |
| Linux | 5.15.0 #16 to a `fishball login:` prompt |
| Errors | none in the boot log |
| Radio | `ad9361-phy`, `xadc` and both DMA cores present |

## Reference: bootgen from source

`bootgen`, which packages `BOOT.bin`, is built from AMD's Apache-2.0 source by
`./devkit setup` (~8 MB, pinned by SHA, about five seconds against the system
OpenSSL). That build is always used, not just when Vivado is absent, so the
packaging output does not depend on which AMD tools are installed.

| | |
|---|---|
| This bootgen vs Vivado's, same inputs | **byte-identical** `BOOT.bin` |
| That image | the one the board boots in the test above |
| `ldd` on this binary | system OpenSSL/libstdc++ only, nothing under `/tools/Xilinx` |
| Rebuilt in a container with `/tools/Xilinx` **not mounted** | same checksum |
| Whole build with `XILINX_DIR=/nonexistent`, no `$DISPLAY`, nothing AMD on `PATH` | same checksum |

Vivado is needed for exactly one thing, synthesising the bitstream, and `--xsa`
skips even that.

## Open item

Hosted CI does not build the FSBL end to end, because it needs an XSA and none
is tracked in the repository. embeddedsw and bootgen both build from source in
seconds; the missing piece is where CI should get a hardware platform from.

## Further reading

- [Building without Vivado](../../docs/building-without-vivado.md): the `--xsa`
  build this makes possible.
- [How it works](../../docs/how-it-works.md): the whole boot chain.
- [Issue #7](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/7):
  the request for a Vitis-free FSBL.
