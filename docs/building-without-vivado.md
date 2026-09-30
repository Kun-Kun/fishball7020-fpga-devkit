# Building the firmware without installing Vivado

Vivado is AMD's FPGA design tool. It is about **50 GB** installed, takes an hour
to set up, and the build spends **20 to 70 minutes** in it every time. If you
are changing a driver, the kernel, or something in the root filesystem, and not
the FPGA design itself, you can skip it and install nothing from AMD. This page
explains how, and what you give up.

## Quick start

```bash
# run from: the repo root
# factory target, with an XSA you already have:
./devkit build --xsa ~/fishball-platform.xsa

# modern target, with the pinned XSA from a published release:
./devkit build --target modern --xsa "$(./firmware-modern/fetch-pinned-xsa.sh)"
```

You need `gcc-arm-none-eabi`, `libnewlib-arm-none-eabi` and an ARM Linux
cross-compiler (`gcc-arm-linux-gnueabi` or `gcc-arm-linux-gnueabihf`); the
[table below](#what-you-need-installed) has the full list.

## The idea

Building the firmware has two halves:

| Half | What it makes | How long | How often it changes |
|---|---|---|---|
| The FPGA design | the **bitstream**, the file that configures the FPGA | 20–70 min | rarely |
| Everything else | boot loader, Linux kernel, root filesystem, packaging | a few minutes | constantly |

A full build redoes the slow half whether or not anything in it changed.

**An XSA is the finished FPGA design saved in one file.** Hand the build one,
and it skips the slow half:

```bash
# run from: firmware/
./scripts/build_all.sh --xsa /path/to/system_top.xsa
```

It is AMD's **hardware platform export**, the handoff file between the FPGA
design flow and the software flow. It is a zip, and you can look inside:

```bash
# run from: the directory holding the XSA
unzip -l system_top.xsa
```

It holds `system_top.bit` (the bitstream) and `ps7_init.c` (code that sets up
the processor's memory controller, clocks and pin multiplexing). Those two are
what the rest of the build needs.

## Is this for you?

**Yes, if:**

- **You re-clone or re-run setup often.** The build's working folder,
  `firmware/src/`, is downloaded fresh and not stored in git, so the Vivado
  project is thrown away every time you set up again. The XSA is the one piece
  of the 70-minute build you can keep.
- **You only care about Linux, not the FPGA.** You can install nothing from AMD
  at all: not Vivado, not Vitis, not a single AMD binary.
- **You are chasing a bug.** Rebuilding the FPGA design between attempts
  changes two things at once. An XSA freezes the hardware so only your software
  differs.

**No, if:**

- You want to change the FPGA design. Then you need Vivado: it is the tool that
  makes the bitstream.
- You only want to change the kernel and flash it. See
  [Change the kernel](building.md#change-the-kernel): rebuild `uImage` alone in a
  few minutes and flash it with `./devkit flash --kernel-only`.

## What you need installed

The **FSBL** (First Stage Boot Loader, the first code the ARM cores run) brings
up the memory controller before anything else can run. Its settings are
specific to this board's layout and live inside the XSA as `ps7_init.c`. It is
compiled from [AMD's public embeddedsw](https://github.com/Xilinx/embeddedsw)
with an ordinary bare-metal cross-compiler, from the same sources Vitis would
use (byte-identical to embeddedsw at `xilinx_v2022.2`), so Vitis is not needed.
Details: [`firmware/fsbl/README.md`](../firmware/fsbl/README.md).

`bootgen`, the tool that packs `BOOT.bin`, is built from AMD's Apache-2.0
source by `./devkit setup` (about 8 MB, pinned by SHA, about five seconds
against your system OpenSSL). That build is used always, whether or not Vivado
is installed, so the output does not depend on which AMD tools you have.

| | Must be installed? | Runs during the build? |
|---|---|---|
| Vivado (~50 GB) | **no**, with `--xsa` | no: saves 20–70 min a build |
| Vitis 2022.2 | **no**: nothing here uses it | no |
| `gcc-arm-none-eabi` + `libnewlib-arm-none-eabi` | **yes**: `apt install`, ~100 MB | yes |
| AMD's embeddedsw | yes: `./devkit setup` fetches ~75 MB, pinned by SHA | yes |
| AMD's bootgen | yes: `./devkit setup` fetches ~8 MB and builds it, ~5 s | yes |
| `g++` + `libssl-dev` | **yes**: to build bootgen; the kernel needs them anyway | yes |
| `gcc-arm-linux-gnueabi` (or `arm-linux-gnueabihf-gcc`) | **yes**: `apt install`; builds U-Boot and the kernel | yes |
| Buildroot's own toolchain | only for the factory root filesystem; Buildroot fetches it itself | only in a full factory build |

`./devkit doctor` checks this list. Missing Vivado is a warning; Vitis is not
checked for at all; a missing `arm-none-eabi-gcc`, or one without the
hard-float multilib (which fails at link with *"uses VFP register
arguments"*), is a failure.

A build with nothing from AMD installed produces the same `BOOT.bin`: the whole
build run with `XILINX_DIR=/nonexistent`, no `$DISPLAY` and nothing AMD on
`PATH` gives the same checksum as one on a machine with Vivado.

## Where to get an XSA

**Option 1: save your own.** If you have ever run a full build, you already
have one. Copy it somewhere safe *before* your next `./devkit setup` wipes it:

```bash
# run from: the repo root
cp firmware/src/hdl/projects/pluto/system_top.xsa ~/fishball-platform.xsa
```

That one file is the durable result of the whole 70 minutes.

**Option 2: download it from a release.** For the modern target, one command
fetches the XSA its releases are built from (the factory release named in
[`firmware-modern/factory-xsa.pin`](../firmware-modern/factory-xsa.pin)) and
refuses it if its sha256 is not the pinned one:

```bash
# run from: the repo root
./devkit build --target modern --xsa "$(./firmware-modern/fetch-pinned-xsa.sh)"
```

By hand, for either target:

```bash
# run on your HOST, from anywhere. --repo is required outside a clone of this
# repository; without it gh exits with "fatal: not a git repository".
gh release download v1.7 -p system_top.xsa \
  --repo matsvandamme/fishball7020-fpga-devkit
sha256sum system_top.xsa
# 47f831009eb19b21a97a8136472d663e32a32cc42a5c26ba5e17f72d4f8f7e0b
```

Or without `gh`:

```bash
# run on your HOST, from anywhere
curl -fLO https://github.com/matsvandamme/fishball7020-fpga-devkit/releases/download/v1.7/system_top.xsa
```

- Use the **newest factory release**; v1.7 is the current one. Its XSA is
  **851 242 B**: a zip whose members come to 6.5 MB uncompressed, most of that
  the bitstream, which compresses well because unused fabric is zeros.
- **v1.6 is the first release with an `.xsa`.** v1.1 to v1.5 have none.
- **Modern releases do not attach one.** That target runs no Vivado and has no
  bitstream of its own; take the `.xsa` from a **factory** release.
- **A release's `.xsa` is that release's FPGA design.** The bitstreams in
  v1.6's and v1.7's differ from each other and from a from-source build of the
  current tree (which has gained patch `0021` since). A board built from a
  release `.xsa` runs that release's design. To check whether a `BOOT.bin`
  carries a given platform's bitstream, byte for byte:
  `./firmware/scripts/check_bootbin.py BOOT.bin --xsa FILE`.

[`release.yml`](../.github/workflows/release.yml) refuses to publish a
**factory** release whose firmware was itself built with `--xsa`, so a released
platform is always one built from source on a machine with a board attached. A
**modern** release is the one exception: its `BOOT.bin` can only come from an
XSA, so the job accepts exactly one, the pinned factory release's (checked
against that release's own asset), and refuses any other.

**Option 3: get one from somebody else.** Anyone who has built this repository
can send you theirs. Read [Trusting an XSA](#trusting-an-xsa) first.

## Doing it

```bash
# run from: firmware/
./scripts/build_all.sh --xsa ~/fishball-platform.xsa
```

**The modern target always works this way.** It has no Vivado path, so `--xsa`
is required:

```bash
# run from: the repo root
./devkit build --target modern --xsa ~/fishball-platform.xsa
```

Both targets import through the same script, `firmware/scripts/import_xsa.sh`,
so they refuse the same wrong files (see
[What can go wrong](#what-can-go-wrong-and-what-it-looks-like)).

Add `--hdl-only` if your kernel, boot loader and root filesystem are already
built and you only want to repackage:

```bash
# run from: firmware/
./scripts/build_all.sh --hdl-only --xsa ~/fishball-platform.xsa
```

The first stage says what it is doing:

```
=== [1/7] Importing a pre-built XSA (Vivado not invoked) ===
    hardware platform: .../system_top.xsa
    bitstream:         2390808 bytes
    provenance:        .../output/xsa-provenance.txt
    NOTE: this design was not implemented here, so there is no timing
          report to check. ./scripts/verify_output.sh will say so.
```

Everything after that is the ordinary build.

### Importing removes this tree's timing reports

The import deletes `timing.rpt` and `utilization.rpt` from the project
directory, so a report left over from an earlier build cannot vouch for a
bitstream it never saw. On a tree that **was** built from source, those were
that build's reports, and `./devkit verify` then has nothing to read.

They can be regenerated without a rebuild: Vivado's run directory still holds
the implemented design, and the two report commands `build_hdl.tcl` runs work
on it. This takes about a minute and reproduces the routed report exactly (WNS
+0.215 ns over 54 211 endpoints for the current design):

```bash
# run from: the repo root
cat > firmware/src/hdl/projects/pluto/regen.tcl <<'EOF'
open_project pluto.xpr
open_run impl_1
report_utilization -file utilization.rpt
report_timing_summary -file timing.rpt
EOF
./devkit container shell -c "source tools/env-vivado.sh && cd firmware/src/hdl/projects/pluto \
    && vivado -mode batch -nojournal -nolog -source regen.tcl"
```

This needs Vivado installed, so it applies only to a tree that was built with
it. A tree that never ran implementation has no `impl_1` to open.

## Checking it worked

```bash
# run from: firmware/
./scripts/verify_output.sh
```

With an imported platform it says that the bitstream was not built here, prints
its md5, and lists the IP blocks that are **in the bitstream**, read from the
platform's own records rather than from the source code in your tree:

```
bitstream was IMPORTED, not built here:
  bitstream md5 6bf9c28daf976ead441dff1e4bd2af9c
IP in the bitstream, from its own system.hwh (not from source):
  axi_ad9361 ... gpio_bitmap_o ... tx_upack
  -> sample-locked GPIO IS in this bitstream
timing: NOT AVAILABLE - this design was not implemented here.
```

The verifier normally checks that the design meets timing. With an imported
design it cannot, because implementation happened on another machine, so it
reports that instead of failing (which would imply something is wrong) or
passing (which would imply it checked).

`output/xsa-provenance.txt` records where the file came from, its md5, and that
IP list, so a board can be traced back to the platform it was built from.

## Does it produce the same firmware?

Yes. Building from an XSA exported by a Vivado run produces a
**byte-identical `BOOT.bin`**:

```
BOOT.bin from the Vivado build: 3fb710d8f990cec8f14d5ca61ca2ddb7
BOOT.bin from --xsa:           3fb710d8f990cec8f14d5ca61ca2ddb7
```

The bitstream inside the XSA is byte-identical to the one a Vivado build copies
out of its run directory (md5 `6bf9c28d…`). The XSA is the designed handoff
point between the two flows, not a shortcut around one.

## What can go wrong, and what it looks like

The import refuses anything it cannot vouch for, with one clear sentence:

| If you pass | You get |
|---|---|
| Something that is not a zip | `ERROR: … is not a readable zip archive.` |
| An XSA exported without the bitstream | `ERROR: … contains no system_top.bit.` |
| An XSA for a different chip | `ERROR: that XSA is not for this board's part (xc7z020clg400-2).` |
| An XSA from a different Vivado version | `ERROR: that XSA was written by a different tool version.` |

The last two are refused up front because a mismatched platform would
otherwise reach the FSBL build and fail there, with an error about a missing
peripheral or a compiler flag rather than about the file you passed.

## Trusting an XSA

**Your own XSA is a cache.** You built it, from sources you can read, on your
machine. Nothing is lost.

**Someone else's XSA is a binary you cannot read.** You can list what is in it,
check that it is for the right chip, and confirm it produces the `BOOT.bin` you
flash. You cannot confirm it matches any particular source code, because a
bitstream cannot be decompiled back into a design. Closed vendor firmware is
the gap this repository exists to fill, so:

- Use your own XSA freely.
- Treat someone else's the way you would treat any binary from a stranger.
- If it matters, build the design yourself once, and keep the XSA.

## See also

- [Building your own firmware](building.md): the full build, including Vivado
- [Change the kernel](building.md#change-the-kernel): if that is all you want
- [The block design](block-design.md): what is in the bitstream
