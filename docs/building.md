# Building your own firmware

How to go from a fresh Ubuntu machine to the five SD-card files that contain
your change, building directly on the host. For the short version, see the
[Quick start](../README.md#quick-start); for what the build produces and why,
[How it works](how-it-works.md). To put the result on the board, see
[Flashing the board](flashing.md).

**The recommended route is [Building in a container](building-in-a-container.md).**
It works on any Linux, installs Vivado for you, and produces a byte-for-byte
identical `BOOT.bin`. Building on the host, as this page describes, needs
Ubuntu 18.04, 20.04 or 22.04: the releases Vivado 2022.2 supports. On anything
newer neither Vivado nor its installer runs.

> **Never written Verilog?** This page assumes you have. The repository ships a
> course written against this board that assumes nothing:
> **[Fabric School](course/index.html)** (54 lessons, or the
> [190-page PDF](course/Fabric-School.pdf)). For the work on this page:
>
> | | |
> |---|---|
> | **4–10** | Verilog itself: your first module, clocks and reset, the two assignments, the latch trap, width and signedness, fixed point, testbenches |
> | **13–18** | **this** block design: what it assumes, the valid strobes and the 2R2T trap, the packers, how samples reach memory, and a worked insertion line by line |
> | **19–23** | doing it yourself: packaging your logic as an IP, pins and constraints, driving Vivado and reading what it says, crossing clock domains, registers Linux can read |
> | **50–51** | projects sized for this board, and the rules to keep in view |
>
> Whether the FPGA fabric is the right place for your code at all:
> [using this board in your own project](your-own-project.md).

**Contents**

- [Requirements](#requirements) · [Install Vivado 2022.2](#install-vivado-20222) · [Get the firmware source](#get-the-firmware-source)
- [Open the block diagram](#open-the-block-diagram) · [Add your own HDL](#add-your-own-hdl) · [Change the kernel](#change-the-kernel)
- [Simulate before you build](#simulating-your-hdl-first) · [Build the firmware](#build-the-firmware)
- [Repository layout](#repository-layout)

## Requirements

**Hardware:** the board, a USB-C cable, and a microSD card with a reader. A
board that still boots can be reflashed over the network instead (see
[Option C](flashing.md#option-c--over-ssh-from-the-running-board-no-card-removal)).
If you will ever loop TX to RX, **an SMA attenuator of at least 20 dB**. A
debug-port cable only if you want the serial console or JTAG.

**Software** (Ubuntu 22.04 LTS; on anything else, use the container):

```bash
# run on your HOST, from anywhere
sudo apt update
sudo apt install -y git build-essential bison flex libssl-dev \
    device-tree-compiler u-boot-tools screen python3 \
    libgmp-dev libmpc-dev libmpfr-dev sshpass iverilog libiio-utils \
    gcc-arm-none-eabi libnewlib-arm-none-eabi gcc-arm-linux-gnueabi
```

- **No extra GCC on 22.04.** Its GCC 11 builds everything. Only on a much newer
  distribution (GCC 14 or later) does one legacy Buildroot host tool need
  `gcc-13` alongside; `build_all.sh` detects this and picks it.
- **`libgmp-dev`, `libmpc-dev`, `libmpfr-dev`** are needed by the kernel's
  GCC-plugin build. Without them stage 4 fails with `fatal error: gmp.h`.
- **`gcc-arm-linux-gnueabi` builds U-Boot and the Linux kernel.** It is a
  *cross-compiler*: it runs on your PC and produces code for the board's ARM
  cores. The hard-float `arm-linux-gnueabihf-gcc` (what Arch and most other
  distributions package) works too: the build compiles U-Boot with
  `-mfloat-abi=soft`, which it needs to get past U-Boot's `-march=armv7-a`
  check, and which changes nothing else because U-Boot is soft-float anyway.
  Prefer `gnueabi` on the factory target: only it rebuilds the factory kernel
  byte for byte, and the build prints a note when it falls back to `gnueabihf`.
  Buildroot brings its own compiler for the userspace, so this choice does not
  affect the root filesystem. On Arch, see
  [An ARM cross-compiler on Arch](#an-arm-cross-compiler-on-arch).
- **`gcc-arm-none-eabi` and `libnewlib-arm-none-eabi` build the boot loader.**
  This is a *different* compiler: it targets the ARM cores with no operating
  system under them, which is the situation the first boot code is in.
  `libnewlib` is the small C library that goes with it. It is required: without
  its hard-float variant the link fails with `uses VFP register arguments`,
  which reads like a mistake in the build and is not. `./devkit doctor` checks
  for both, including that variant.
- **No display is needed.** Nothing in the build opens a window, so a headless
  machine (a server, a CI runner, an SSH session) is fine, and `xvfb` is not
  required.
- `sshpass` is what `./devkit flash`, `verify --board` and `gpio-check` use to
  reach the board; `iverilog` runs the HDL simulation; `libiio-utils` gives you
  `iio_attr` and `iio_info` for inspecting the board. `screen` is only for the
  serial console.

### An ARM cross-compiler on Arch

Arch has no ARM Linux cross-compiler in its official repositories. Two routes:

**Arm's prebuilt toolchain** (minutes, no root). Download
`arm-gnu-toolchain-<version>-x86_64-arm-none-linux-gnueabihf.tar.xz` and its
`.sha256asc` from [Arm's download page](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads),
then link its tools under the `arm-linux-gnueabihf-` names the build looks for:

```bash
# run from: the directory holding the download
sha256sum -c arm-gnu-toolchain-*-x86_64-arm-none-linux-gnueabihf.tar.xz.sha256asc
mkdir -p ~/.local/opt ~/.local/bin
tar -xJf arm-gnu-toolchain-*-x86_64-arm-none-linux-gnueabihf.tar.xz -C ~/.local/opt
for t in ~/.local/opt/arm-gnu-toolchain-*-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-*; do
    n=$(basename "$t"); ln -sf "$t" ~/.local/bin/"${n/arm-none-linux-gnueabihf-/arm-linux-gnueabihf-}"
done
arm-linux-gnueabihf-gcc --version     # ~/.local/bin must be on PATH
```

Version 15.2.rel1 builds both targets' U-Boot, the 6.12 kernel and the modern
`BOOT.bin`. If `/usr/bin` holds other `arm-linux-gnueabihf-*` tools (for example
from a half-finished AUR install), they come first on `PATH`; remove them so all
the tools come from one toolchain.

**The AUR packages** (hours, needs root). `arm-linux-gnueabihf-gcc` is built in
stages that replace each other, and an AUR helper cannot resolve the chain in one
go: `yay -S arm-linux-gnueabihf-gcc` stops after binutils and the kernel headers.
Install the stages one at a time, in this order:

```bash
# run on your HOST
yay -S arm-linux-gnueabihf-gcc-stage1
yay -S arm-linux-gnueabihf-glibc-headers
yay -S arm-linux-gnueabihf-gcc-stage2
yay -S arm-linux-gnueabihf-glibc
yay -S arm-linux-gnueabihf-gcc
```

## Install Vivado 2022.2

Vivado is AMD's FPGA design tool. It is about 50 GB, and the build spends
20 to 70 minutes in it every time.

> **You may not need Vivado at all.** If you are changing drivers, the kernel or
> the root filesystem rather than the FPGA design, you can build from a
> ready-made hardware platform and install nothing from AMD:
> **[Building without Vivado](building-without-vivado.md)**.

> If your distribution is newer than 22.04, the installer will most likely not
> run either: it is the same Java/GTK application as Vivado. Install it from
> inside the container instead:
> [Installing Vivado in the first place](building-in-a-container.md#installing-vivado-in-the-first-place).

The Zynq-7020 is covered by Xilinx's **free WebPACK licence**: no purchase, no
licence file.

1. Create an account at [xilinx.com](https://www.xilinx.com) and go to the
   [2022.2 downloads page](https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/vivado-design-tools/2022-2.html).
2. Download the **Vitis** unified installer for Linux. Despite the name, this
   one installer offers both products and you choose in the GUI: you want
   **Vivado**. Vitis itself is not used by this project. The boot loader is
   built from AMD's embeddedsw sources with `gcc-arm-none-eabi`, and `bootgen`
   is built from AMD's published source by `./devkit setup`. Vivado is needed
   for one thing only: synthesising the FPGA bitstream.
3. Run the installer:

   ```bash
   # run on your HOST, from the directory holding the installer
   chmod +x Xilinx_Unified_2022.2_*.bin && ./Xilinx_Unified_2022.2_*.bin
   ```

4. In the GUI: choose **Vivado**, edition **Vivado ML Standard**; under device
   families select only **Zynq-7000** (brings ~130 GB down to ~30 GB); **keep
   the default path `/tools/Xilinx`**, which `tools/env-vivado.sh` points at.

**Always `source tools/env-vivado.sh`, never Vivado's own `settings64.sh`.**
Vivado 2022.2 is linked against `libtinfo.so.5`, `libncurses.so.5` and
`libssl.so.1.1`, which a default 22.04 does not have. The script prepends
vendored copies to `LD_LIBRARY_PATH` before sourcing `settings64.sh`, and
changes nothing system-wide. It does this only where the distribution has no
`libtinfo.so.5` of its own: the copies were extracted on 22.04 and need
`GLIBC_2.33`, so on an older release they break Vivado with
`librdi_commontasks.so: GLIBC_2.33 not found`, an error naming a library that
is not the problem.

## Get the firmware source

```bash
# run from: wherever you want the devkit to live (e.g. ~)
git clone https://github.com/matsvandamme/fishball7020-fpga-devkit.git
cd fishball7020-fpga-devkit/firmware
./scripts/setup.sh
```

`./devkit setup` from the repo root does the same thing. It clones the upstream
source (a Zynq-7020 port of ADI's `plutosdr-fw`) into `src/` and applies this
repository's `patches/`: the board's device tree, six fixes to the vendor's init
scripts, the sample-locked GPIO feature, and the transmitter-safety patches.
[`firmware/patches/README.md`](../firmware/patches/README.md) has a table of
them all and a section on each; read it before dropping any. `src/` is
gitignored; re-run `setup.sh` any time for a clean slate.

> **Where to run things:** `./devkit …` runs from the **repo root**. The raw
> scripts run from **`firmware/`** unless the block says otherwise. Each block
> states its directory on its first line.

## Open the block diagram

> **[The stock block design](block-design.md)** walks through every IP
> block, the wiring, clock domains, address map, and what is safe to change.

The Vivado project does not exist until the first build (only the `.tcl` that
generates it does), so build once first with `./devkit build`. `--hdl-only`
needs a previous full build. Then:

```bash
# run from: firmware/
source ../tools/env-vivado.sh
cd src/hdl/projects/pluto
vivado pluto.xpr
```

In the GUI: **Sources → Design Sources → system_top → system_i**,
right-click **Open Block Design**.

## Add your own HDL

Received samples do not go straight to memory. Channel 0 runs through ADI's
programmable FIR (finite impulse response) decimator and interpolator; channel 1
bypasses filtering entirely:

```
                            AD9361 (physical LVDS pins)
                                    │
                             ┌──────▼───────┐
                             │  axi_ad9361   │
                             └──┬────────▲───┘
      RX ch.0: adc_data_i0/q0 ──┤         ├── TX ch.0: dac_data_i0/q0
      RX ch.1: adc_data_i1/q1 ──┤         ├── TX ch.1: dac_data_i1/q1
                                │         │
                    ┌───────────▼──┐   ┌──┴────────────┐
        ch.0 only:  │rx_fir_       │   │tx_fir_        │  ch.0 only:
     (decimation,   │decimator     │   │interpolator   │  (interpolation,
      8x, 2x taps)  └──────┬───────┘   └───────▲───────┘   2x/8x taps)
                           │                     │
      ch.1 connects  ┌─────▼──────┐       ┌──────┴─────┐  ch.1 connects
      directly, no   │   cpack     │       │  tx_upack  │  directly, no
      filter ────────►(util_cpack2)│       │(util_upack2)◄──── filter
                     └─────┬──────┘       └──────▲─────┘
                           │                       │
                    ┌──────▼──────┐         ┌──────┴──────┐
                    │  adc_dma     │         │  dac_dma     │
                    │ (axi_dmac)   │         │ (axi_dmac)   │
                    └──────────────┘         └──────────────┘
                     ▲ YOU ARE HERE: insert custom logic between
                     axi_ad9361 and cpack/tx_upack (channel 1),
                     or before/after the FIR blocks (channel 0)
```

This is upstream's datapath. The default build also feeds RX channel 1 through
the decimator (patch `0021`, which takes `cpack`'s inputs 2 and 3 from the
filter outputs); `STOCK_RX_FILTER=1` builds the design shown here.

- **Channel 1, in the design shown, has no filter in the path**: it is wired
  straight from `axi_ad9361` to `cpack`/`tx_upack`. The cleanest insertion
  point: break the connection in the block design, insert your block (mirroring
  the `ad_connect axi_ad9361/adc_data_i1 …` calls in `system_bd.tcl`), and
  reconnect to `cpack`'s `enable_2`/`fifo_wr_data_2` (and `_3` for Q).
- **Channel 0** routes through 129-tap FIRs that decimate and interpolate by 8,
  built by `ad_add_decimation_filter`/`ad_add_interpolation_filter` in
  `system_bd.tcl` from Xilinx's `fir_compiler` IP, with taps from
  `library/util_fir_int/coefile_int.coe`. Insert before them (raw, full rate)
  or after, or swap the `.coe` to change the response without touching wiring.
- Both channel-0 groups run on `axi_ad9361/l_clk`; match that clock domain.
- Edit graphically (drag in IP, wire it, **Create HDL Wrapper**) or edit
  `system_bd.tcl` directly.

> **`library/util_fir_int/` and `library/util_fir_dec/` are not used.** Neither
> has a `component.xml`, so neither is ever packaged, and their `.v` files are
> dead code. Only `coefile_int.coe` is used, and the RX decimator and TX
> interpolator are passed **the same** file, so editing it in place changes
> both.

> **Worked examples.**
> **[Isolating one FM channel in the FPGA](wbfm-channelizer.md)** inserts a
> custom Verilog block into the channel-0 RX path, designs and checks new FIR
> coefficients from a script, and explains why "just lowpass the channel"
> cannot work.
>
> A smaller reference design ships **enabled in the base firmware**:
> [the sample-locked GPIO outputs](tx-gpio-bitmap.md). `tx_gpio_bitmap.v` is
> about thirty lines and shows the whole pattern: a module, a block-design tap,
> a pin constraint and a driver attribute.

### Rebuilding after a GUI block-design edit

`build_hdl.tcl` opens the existing `pluto.xpr` and does a full `reset_run
synth_1`, so a GUI edit flows through to `BOOT.bin`. Before building:

1. **Save the block design** (`Ctrl-S`). An unsaved edit is not in `pluto.xpr`
   and the build silently leaves it out.
2. **Validate Design (F6).**
3. **Close Vivado.** The GUI holds a project lock.

```bash
# run from: firmware/
./scripts/build_all.sh
```

GUI edits live in `src/`, which is gitignored and regenerated by `setup.sh`.
To keep a change, port it into `system_bd.tcl` and add it to `patches/`.

## Change the kernel

The FPGA is half the board. The other half is a Linux kernel with ADI's
drivers in it, and much of the board's *behaviour* (what appears in `/sys`,
when the transmitter is muted, what the serial number is) lives there rather
than in the fabric. **[Changing the kernel](kernel.md)** covers what is
already patched and why, the two-minute kernel-only rebuild loop, the kernel
options that matter, debugging a driver, and making a change stick as a patch.
Flash a kernel change with `./devkit flash --kernel-only`.

**There are two kernels.** This page builds `firmware/`, the factory
reconstruction on Linux 5.15. [`firmware-modern/`](../firmware-modern/README.md)
builds **6.12 LTS** from Analog Devices instead, with the same
transmitter-safety patches rebased onto it and the same RF behaviour on
hardware. Use it for driver work: its tree is just a kernel, its device tree is
a 228-line overlay rather than a 1003-line flat file, and it needs no Vivado.
Nothing else on the SD card changes, so a kernel swap is one file:

```bash
# run from: the repo root
./firmware-modern/setup.sh
# ...build uImage (see kernel.md), then:
./devkit flash --target modern --kernel-only
```

## Simulating your HDL first

A Vivado build takes 20 minutes with `--hdl-only` and 70 from cold, and then
you still have to flash. Synthesis also cannot tell you the logic is *wrong*,
only that it fits and meets timing. So check the logic first:

```bash
# run from: firmware/
./sim/run_sim.sh
```

It needs only `iverilog`, takes about a second, and checks the repository's
custom HDL against a golden model (a straightforward software description of
what the module should compute). It works whether or not you applied the
optional patches: if a module is not in `src/`, the runner takes it from its
patch file.

```
== ad_fs4_ddc ==        PASS  473 checks, no mismatches against the golden model
== tx_gpio_bitmap ==    PASS  2092 checks
```

**The most important check in both modules is gapped valid.** A counter must
advance once per *sample*, not once per *clock*, and on this board `valid` is
intermittent: in 2R2T mode the AD9361 asserts `adc_valid` every second clock.
Getting this wrong looks correct in a back-to-back simulation, synthesises
cleanly, meets timing, and is wrong on hardware.

A passing suite only counts once you have seen it fail:

```bash
# run from: firmware/
./sim/run_sim.sh --mutate
```

This breaks the modules ten ways (a phase counter moved out of its guard, sign
errors, I/Q swapped, an unregistered output; a nibble captured every clock,
pins left tristated, a reversed mux, one synchroniser stage instead of two, a
reset leaving a stale value) and reports any mutant the testbenches fail to
catch. CI runs both. A mutation run can expose a weak test as well as a weak
module: the stale-reset mutant exposed a reset test in which a sample landing
between the reset and the check hid the stale value.

If you add HDL, add a testbench beside these, and at least one mutant.

## Build the firmware

> To skip the FPGA stage, `./scripts/build_all.sh --xsa FILE` imports an
> already-built hardware platform and does not run Vivado. See
> [Building without Vivado](building-without-vivado.md).

```bash
# run from: firmware/
./scripts/build_all.sh
```

**Iterating on HDL?** Use `--hdl-only`. Stages 3–5 produce byte-identical
output when only the FPGA design changed, and they are most of the wall time:
about 20 minutes instead of 70. It reuses the existing kernel, U-Boot and root
filesystem, and refuses to run if no previous full build produced them.

| Stage | What it does |
|---|---|
| 1. HDL | Synthesises and implements `pluto.xpr`, exports the hardware platform |
| 2. FSBL | Builds the first-stage boot loader from AMD's embeddedsw sources with `gcc-arm-none-eabi`, against this design's hardware platform |
| 3. U-Boot | Built from `zynq_pluto_defconfig`, patched to the real board's boot defaults |
| 4. Kernel | `uImage` + `zynq-pluto-sdr-fishball.dtb` |
| 5. Root filesystem | Buildroot, which fetches its own toolchain; auto-retries a known git-archive hash-drift issue |
| 6. `uEnv.txt` | Generated from the just-built U-Boot's own defaults |
| 7. Packaging | `bootgen`, built from AMD's Apache-2.0 source, combines FSBL + bitstream + U-Boot into `BOOT.bin` |

A full run is 45–90 minutes; HDL and Buildroot are the long stages. Every
stage runs every time (there is no per-stage skip logic), but Vivado's
incremental synthesis rebuilds only what changed.

## Repository layout

```
fishball7020-fpga-devkit/
├── README.md                            ← start here: getting going with the devkit
├── LICENSE                              multiple licenses apply; read it for the breakdown
│
├── .claude/skills/                      ← Agent Skill, loaded automatically by Claude Code
│   └── fishball7020-firmware/
│       ├── SKILL.md                     the rules, the map, what a healthy board measures
│       └── references/                  gain tables · measuring · board access · debugging
│
├── docs/                                ← everything the README links to: building, flashing,
│   │                                      safety, the GPIO feature, measurements, hardware
│   ├── img/                             figures, and the scripts + data that draw them
│   └── vendor/                          the vendor schematic this board matches
│
├── devkit                               ← one entry point: doctor · setup · sim · build
│                                          verify · flash · selftest · gpio-check · status
├── tools/
│   ├── env-vivado.sh                    ← source this before any vivado command
│   ├── flash.sh                         ← flash the running board over the network, safely
│   ├── make-sd-card.sh                  write a spare factory-layout card from a reader
│   ├── tx-gpio-bitmap-check.py          checks the TX-nibble-to-GPIO feature on hardware
│   ├── sample_gpio_clock.py             drive the sample-locked pins as clocks from your host
│   ├── setup-hardware-runner.sh         register this machine as the hardware-CI runner
│   │                                      (those workflows stay inert until you do)
│   ├── selftest/                        ← is the board damaged? measures and says
│   │   ├── sdr_selftest.py              rails, BIST, receiver, and an RF loopback sweep
│   │   ├── iiod_min.py                  libiio's network protocol over a socket, stdlib only
│   │   └── test_dsp.py                  asserts the measurement maths, no board needed
│   ├── container/                       the pinned build image and its launcher
│   └── legacy-libs/libs/                vendored libtinfo5/libncurses5/libssl1.1
│
├── firmware-modern/                     Linux 6.12 and a Debian root; no HDL, no bitstream.
│                                          It boots on the BOOT.bin firmware/ builds
│
└── firmware/       THE FPGA LIVES HERE. Also the factory kernel (Linux 5.15) and
    │               the byte-identical device tree.
    ├── README.md                       deep reference: exact patch list, provenance,
    │                                   byte-for-byte comparison against real hardware
    ├── patches/                        all applied by setup.sh:
    │   │                               0001 fixes + hw_serial · 0002 device tree
    │   │                               0004 TX mute · 0005 keep a gain set before streaming
    │   │                               0006 sample-locked GPIO · 0007 its IIO attribute
    │   │                               0008 gpio-line-names for those four pins
    │   │                               0009 the bit-map flag's CDC constraint, fixed
    │   │                               0011 probe at FULL attenuation, not 10 dB
    │   │                               0012 USER LED follows the transmitter
    │   │                               0013 stable MAC + DHCP hostname · 0014 name it fishball
    │   │                               0015 mute when the DAC starves
    │   │                               0016 a TX-disable latch debugfs cannot clear
    │   │                               0017 count TX DMA underflows
    │   │                               0018 refuse to get louder when the die is hot
    │   │                               0020 host tools use u-boot's own libfdt
    │   │                               0021 filter BOTH RX channels (STOCK_RX_FILTER=1
    │   │                                    opts out; uses 22 more DSP48s)
    │   │                               (no 0003 or 0010: patches/README.md says why;
    │   │                                0019 exists only in firmware-modern/patches/)
    │   └── optional/                   NOT applied: worked examples
    │       └── 0003-wbfm-channelizer.patch         (docs/wbfm-channelizer.md)
    ├── fsbl/                           the first-stage boot loader, built without Vitis
    ├── scripts/
    │   ├── doctor.sh                   (run first) can this machine build?
    │   ├── setup.sh                    (run once) clones upstream into src/, applies patches
    │   ├── build_all.sh                (run every time) full build → output/
    │   ├── build_hdl.tcl               Vivado batch: synth → impl → export platform
    │   ├── import_xsa.sh               the --xsa path: import a ready-made platform
    │   ├── fix_and_retry_buildroot.sh  auto-repairs a known Buildroot hash-drift issue
    │   ├── boot.bif                    bootgen recipe: FSBL + bitstream + U-Boot → BOOT.bin
    │   ├── gen_fir_coe.py/.m           designs and checks FIR coefficients
    │   ├── verify_output.sh            checks output/ and reports what is in the bitstream
    │   ├── check_bootbin.py            does a BOOT.bin carry a given XSA's bitstream?
    │   └── coefile_*.coe               generated coefficients, copied into src/ by build_all
    ├── sim/                            ← simulate the custom HDL in a second, no Vivado
    │   ├── run_sim.sh                  runs it; --mutate shows the testbenches can fail
    │   ├── tb_ad_fs4_ddc.v             golden-model testbench for the channelizer
    │   └── tb_tx_gpio_bitmap.v         golden-model testbench for the GPIO bit-map
    ├── src/                            ← created by setup.sh, NOT committed (see .gitignore)
    │   ├── hdl/projects/pluto/         ← the Vivado project (system_bd.tcl, system_top.v,
    │   │                                 system_constr.xdc: what you edit to add HDL)
    │   ├── linux/  u-boot-xlnx/  buildroot/
    └── output/                         ← the 5 final SD-card files
```
