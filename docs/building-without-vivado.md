# Building the firmware without installing Vivado

Vivado is AMD/Xilinx's FPGA design tool. It is about **50 GB** installed, takes
an hour to set up, and the build needs it for **20 to 70 minutes** every time.

If you are here to change a driver, the kernel, or something in the root
filesystem — and not to change the FPGA design itself — you can skip all of
that. This page explains how, and what the catch is.

---

## First, the idea

Building the firmware has two halves:

| Half | What it makes | How long | How often it changes |
|---|---|---|---|
| The FPGA design | the **bitstream** — the file that configures the FPGA | 20–70 min | almost never |
| Everything else | boot loader, Linux kernel, root filesystem, packaging | a few minutes | constantly |

Today, a full build redoes the slow half whether or not anything in it changed.
That is like recompiling a library you have never edited every time you build
your own program.

**An XSA is the finished FPGA design saved in one file.** Hand the build one,
and it skips the slow half:

```bash
# run from: firmware/
./scripts/build_all.sh --xsa /path/to/system_top.xsa
```

<details>
<summary>What "XSA" actually stands for, if you care</summary>

It is AMD/Xilinx's **hardware platform export** — the handoff file between the
FPGA design flow and the software flow. It is a zip, and you can look inside:

```bash
# run from: anywhere
unzip -l system_top.xsa
```

You will see `system_top.bit` (the bitstream) and `ps7_init.c` (code that sets
up the processor's memory controller, clocks and pin multiplexing). Those two
are what the rest of the build needs.
</details>

## Is this for you?

**Yes, if any of these sound like you:**

- *"I keep re-cloning this repo."* The build's working folder, `firmware/src/`,
  is downloaded fresh and deliberately not stored in git — so the Vivado
  project is thrown away every time you set up again. The XSA is the only piece
  of that 70-minute build you can keep.
- *"I only care about Linux, not the FPGA."* You can install **nothing from AMD
  at all** — not Vivado, not Vitis, not a single AMD binary.
- *"I am chasing a bug."* Rebuilding the FPGA design between attempts changes
  two things at once. An XSA freezes the hardware so only your software differs.

**No, if:**

- You want to change the FPGA design. Then you need Vivado — that is the tool
  that makes the bitstream.
- You only want to change the kernel and flash it. You do not need this page at
  all: see [Change the kernel](building.md#change-the-kernel), rebuild `uImage`
  alone in a few minutes and flash it with `./devkit flash --kernel-only`.

## This used to need Vitis, then Vivado. Now it needs neither

This page spent most of its life saying *"this skips Vivado, it does **not**
skip Vitis"*. That stopped being true on 2026-09-28. Vitis was a ~30 GB install
that existed here to compile one file; it is now an `apt install` instead.

For a while this still meant installing Vivado anyway, because `bootgen` — the
tool that packs `BOOT.bin` — lived inside it. That went too on 2026-09-28:
bootgen is now built from AMD's own Apache-2.0 source. See the note under the
table.

The **FSBL** — the First Stage Boot Loader, the first code the ARM cores run —
brings up the memory controller before anything else can, and the settings for
that are specific to this board's layout. They live inside the XSA as
`ps7_init.c`. Compiling them was the *only* thing Vitis was here for.

It is now compiled from [AMD's public
embeddedsw](https://github.com/Xilinx/embeddedsw) with an ordinary bare-metal
cross-compiler. The sources are the same ones Vitis instantiated — verified
byte-for-byte against `xilinx_v2022.2` — and given the same compiler the result
was byte-identical to what Vitis produced. A board has since booted the
distro-toolchain build, and the xsct path was deleted on 2026-09-28. See
[`firmware/fsbl/README.md`](../firmware/fsbl/README.md).

So the shopping list is now:

| | Must be installed? | Actually runs? |
|---|---|---|
| Vivado (~50 GB) | **no**, with `--xsa` | no — saves 20–70 min a build |
| Vitis 2022.2 | **no** — nothing here uses it | no |
| `gcc-arm-none-eabi` + `libnewlib-arm-none-eabi` | **yes** — `apt install`, ~100 MB | yes |
| AMD's embeddedsw | yes — `./devkit setup` fetches ~75 MB, pinned by SHA | yes |
| AMD's bootgen | yes — `./devkit setup` fetches ~8 MB and builds it, ~5 s | yes |
| `g++` + `libssl-dev` | **yes** — to build bootgen; the kernel needs them anyway | yes |
| The Linaro cross-compiler | yes — the build makes it for you | yes |

**`bootgen` used to be the one Xilinx binary still required**, and it was the
only reason Vivado had to be installed for an `--xsa` build that never ran it.
AMD publishes its source under Apache-2.0, so `./devkit setup` now clones it
(~8 MB, pinned by SHA) and builds it — about five seconds against your system
OpenSSL. That build is what packages `BOOT.bin`, always, whether or not you have
Vivado, so what comes out does not depend on which AMD tools happen to be
installed.

It was checked the only way worth checking: the `BOOT.bin` it produces is
**byte-identical** to the one Vivado's own bootgen produces, and that image is
the one a board has actually booted. The whole build was then re-run with
`XILINX_DIR=/nonexistent`, no `$DISPLAY`, and nothing AMD on `PATH` — same
checksum.

`./devkit doctor` reflects all of this: missing Vivado is a warning, missing
Vitis is not checked for at all any more, and a missing `arm-none-eabi-gcc` —
or one without the hard-float multilib, which fails at link with an obscure
*"uses VFP register arguments"* — is the thing it fails on.

## Where to get an XSA

**Option 1 — save your own.** If you have ever run a full build, you already
have one. Copy it somewhere safe *before* your next `./devkit setup` wipes it:

```bash
# run from: the repo root
cp firmware/src/hdl/projects/pluto/system_top.xsa ~/fishball-platform.xsa
```

That one file is the durable result of the whole 70 minutes.

**Option 2 — download it from a release.** This is the easy path, and the one
most people want:

```bash
# run from: anywhere. --repo is not optional outside a clone of this
# repository - without it gh exits with "fatal: not a git repository".
gh release download v1.6 -p system_top.xsa \
  --repo matsvandamme/fishball7020-fpga-devkit
sha256sum system_top.xsa
# 27798996fe4df34865ac6bd908f9c7048edf835252f987a22d5e5055ab0d15f0
```

Or without `gh` at all:

```bash
curl -fLO https://github.com/matsvandamme/fishball7020-fpga-devkit/releases/download/v1.6/system_top.xsa
```

**v1.6 is the first release that carries one**, so do not go looking in v1.1,
v1.2, v1.4 or v1.5 — they predate the workflow that attaches it, and this page
used to promise otherwise. The `.xsa` is **851 240 B**: a zip whose members come
to 6.9 MB uncompressed, most of that the bitstream, which compresses well because
unused fabric is zeros.

`target=modern` does **not** attach one, and that is correct rather than an
oversight: that target runs no Vivado and has no bitstream of its own. Take the
`.xsa` from a **factory** release.

The gate behind this is the point rather than an obstacle.
[`release.yml`](../.github/workflows/release.yml) refuses to publish a release
whose firmware was itself built with `--xsa`, so a released platform is always
one built from source on a machine with a board attached. Publishing a
convenient copy of somebody's local file would be worth less than publishing
nothing — which is why, while no release had one, this page could not simply be
"fixed" by uploading the copy sitting in this tree.

**Option 3 — get one from somebody else.** Anyone who has built this repo can
send you theirs. Read the honesty section at the bottom before you do.

## Doing it

```bash
# run from: firmware/
./scripts/build_all.sh --xsa ~/fishball-platform.xsa
```

Add `--hdl-only` if your kernel, boot loader and root filesystem are already
built and you only want to repackage:

```bash
# run from: firmware/
./scripts/build_all.sh --hdl-only --xsa ~/fishball-platform.xsa
```

The first stage will say what it is doing:

```
=== [1/7] Importing a pre-built XSA (Vivado not invoked) ===
    hardware platform: .../system_top.xsa
    bitstream:         2390808 bytes
    provenance:        .../output/xsa-provenance.txt
    NOTE: this design was not implemented here, so there is no timing
          report to check. ./scripts/verify_output.sh will say so.
```

Everything after that is the ordinary build, unchanged.

## Checking it worked

```bash
# run from: firmware/
./scripts/verify_output.sh
```

With an imported platform it tells you plainly that the bitstream was not built
here, prints its md5, and lists the IP blocks that are **actually in the
bitstream** — read from the platform's own records, not from the source code in
your tree:

```
bitstream was IMPORTED, not built here:
  bitstream md5 6bf9c28daf976ead441dff1e4bd2af9c
IP in the bitstream, from its own system.hwh (not from source):
  axi_ad9361 ... gpio_bitmap_o ... tx_upack
  -> sample-locked GPIO IS in this bitstream
timing: NOT AVAILABLE - this design was not implemented here.
```

That last line matters. Normally the verifier checks that the design meets
timing. It cannot, because the design was implemented on somebody else's
machine — so it says so, rather than failing (which would imply something is
wrong) or passing quietly (which would imply it checked).

`output/xsa-provenance.txt` records where the file came from, its md5, and that
IP list, so a board can be traced back to the platform it was built from.

## Does it really produce the same firmware?

Yes, and it is checkable. Building from an XSA exported by a Vivado run produces
a **byte-identical `BOOT.bin`**:

```
BOOT.bin from the Vivado build: 3fb710d8f990cec8f14d5ca61ca2ddb7
BOOT.bin from --xsa:           3fb710d8f990cec8f14d5ca61ca2ddb7
```

The bitstream inside the XSA is likewise byte-identical to the one a Vivado
build copies out of its run directory (md5 `6bf9c28d…`), which is why this works
at all — the XSA is the *designed* handoff point, not a shortcut around one.

## What can go wrong, and what it looks like

The import refuses anything it cannot vouch for, with one clear sentence:

| If you pass | You get |
|---|---|
| Something that is not a zip | `ERROR: … is not a readable zip archive.` |
| An XSA exported without the bitstream | `ERROR: … contains no system_top.bit.` |
| An XSA for a different chip | `ERROR: that XSA is not for this board's part (xc7z020clg400-2).` |
| An XSA from a different Vivado version | `ERROR: that XSA was written by a different tool version.` |

The last two matter more than they look: a mismatched platform would otherwise
sail into the FSBL build and fail there, where the error is about a missing
peripheral or a compiler flag and not about the file you passed.

## Being honest about what you have given up

This is the part worth reading twice.

**Your own XSA is a cache.** You built it, from sources you can read, on your
machine. Nothing is lost.

**Someone else's XSA is a binary you cannot read.** You can list what is in it,
you can check it is for the right chip, and you can confirm it produces the
`BOOT.bin` you flash. You cannot confirm it matches any particular source code,
because a bitstream cannot be decompiled back into a design.

That is precisely the situation this repository exists to get you *out* of —
the README's own words are that vendor firmware "does not include editable HDL
sources, which is the gap this repo fills". So:

- Use your own XSA freely.
- Treat someone else's the way you would treat any binary from a stranger.
- If it matters, build the design yourself once, and keep the XSA.

## See also

- [Building your own firmware](building.md) — the full build, including Vivado
- [Change the kernel](building.md#change-the-kernel) — if that is all you want
- [The block design](block-design.md) — what is actually in the bitstream
