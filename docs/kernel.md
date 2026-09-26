# Changing the kernel

The FPGA is half the board. The other half is a Linux kernel with ADI's drivers
in it, and much of the board's *behaviour* — what appears in `/sys`, when the
transmitter is muted, what the serial number is — lives there, not in fabric.

Four terms: **the kernel** is Linux itself, built as one file (`uImage`); **a
driver** is the kernel code operating a device (here: the AD9361 and the FPGA's
capture/playback blocks); **the device tree** (`devicetree.dtb`) is a data file
describing what hardware exists and where, compiled from `.dts`; **a defconfig**
is a saved set of build options. You are **cross-compiling**, hence
`ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-` everywhere.

## Which kernel

There are two, and picking the wrong one wastes an afternoon:

| | `firmware/` | `firmware-modern/` |
|---|---|---|
| Linux | **5.15.0**, the vendor's fork of a fork | **6.12.0 LTS**, Analog Devices' `main` |
| source appears at | `firmware/src/linux` (one flattened monorepo with U-Boot and Buildroot beside it) | `firmware-modern/src/linux` (just the kernel) |
| created by | `./devkit setup` | `./firmware-modern/setup.sh` |
| device tree | `arch/arm/boot/dts/zynq-pluto-sdr-fishball.dts`, 1003 lines, flat | `arch/arm/boot/dts/xilinx/zynq-pluto-sdr-fishball.dts`, ~200 lines, an overlay on ADI's `zynq-pluto-sdr.dtsi` |
| defconfig | `zynq_pluto_defconfig` | `fishball_defconfig` |
| patches | `firmware/patches/`, 16 of them | `firmware-modern/patches/`, nine drivers-only |

**Use `firmware-modern/` unless you specifically need the factory kernel.** It is
a current LTS, its device tree is 200 lines rather than 1003, and the same nine
transmitter-safety patches are on it — measured on hardware, not assumed.
`firmware/` exists because the byte-identical factory claim is only meaningful
against the factory kernel. [Why 6.12 and not
mainline](../firmware-modern/README.md#why-adi-612-and-not-mainline-72).

Everything below applies to both unless it says otherwise. What differs is
mostly where files are, and that a 6.12 driver change is a patch in
`firmware-modern/patches/` rather than in `firmware/patches/`.

## What is already patched, and why

| Patch | Touches | Does |
|---|---|---|
| `0001-fishball7020-fixes.patch` | buildroot scripts | six upstream fixes, mints a persistent `hw_serial` on first boot |
| `0002-add-fishball-devicetree.patch` | `arch/arm/boot/dts/` | the board's device tree, as editable source |
| `0004-mute-tx-when-no-dma-stream.patch` | `drivers/iio/adc/ad9361.*`, `drivers/iio/frequency/cf_axi_dds*` | mutes the transmitter whenever no DMA buffer streams |
| `0005-dont-clobber-a-gain-set-before-streaming.patch` | the same two drivers | stops the unmute overwriting a gain you set before starting |

Reading those is the fastest way to see how a change here is structured; `0005`
is the smallest.

`firmware-modern/patches/` carries the same transmitter-safety story on 6.12 —
`0004`, `0005`, `0007`, `0012`, `0015`, `0016`, `0017`, `0018` rebased, plus one
that only exists there. **Six of the eight rebased patches add byte-for-byte
identical code**, so reading either set teaches the other.
[What the rebase cost](../firmware-modern/patches/README.md).

The ninth, `0019`, is worth reading on its own: `ad9361_clear_state()` memsets
the struct that held the attenuation the kernel restores when it unmutes, and
0 mdB is full output — so a debugfs `initialize` followed by any transmit stream
keyed the transmitter flat out. That was found by re-testing the series on
hardware after the rebase, and **the same code is on 5.15**. It is the third
safety-relevant field to be moved out of that struct, after `0016`'s latch and
`0018`'s temperature limit.

## The build

Step 5 builds the kernel with everything else, but while iterating you want a
two-minute cycle, not seventy:

```bash
# run from: firmware/
SRC=$PWD/src
PATH="$SRC/buildroot/output/host/bin:$SRC/buildroot/output/host/sbin:$PATH" \
  make -C "$SRC/linux" -j"$(nproc)" ARCH=arm \
  CROSS_COMPILE=arm-linux-gnueabihf- uImage UIMAGE_LOADADDR=0x8000
cp src/linux/arch/arm/boot/uImage output/uImage
```

On `firmware-modern/` it is one command and no `PATH` juggling, because the
defconfig names everything and the tree is just a kernel:

```bash
# run from: firmware-modern/src/linux
CROSS=../../../firmware/src/buildroot/output/host/bin/arm-linux-gnueabihf-
make ARCH=arm CROSS_COMPILE=$CROSS fishball_defconfig
make ARCH=arm CROSS_COMPILE=$CROSS uImage LOADADDR=0x8000 -j$(nproc)
make ARCH=arm CROSS_COMPILE=$CROSS DTC_FLAGS=-@ xilinx/zynq-pluto-sdr-fishball.dtb
cp arch/arm/boot/uImage arch/arm/boot/dts/xilinx/zynq-pluto-sdr-fishball.dtb \
   ../../output/                      # the .dtb is renamed by flash.sh
```

Any `arm-linux-gnueabihf` GCC will do — the 2018-era Linaro 7.3 above is just
the one `firmware/` already built. A kernel takes about two minutes.

Then flash **`uImage` alone** — the other four files haven't changed — and
reboot; the board is back in about fifteen seconds. Point `flash.sh` at the
right output directory:

```bash
# run from: the repo root
FW_OUTPUT=$PWD/firmware-modern/output ./tools/flash.sh --kernel-only
```

The device tree is a separate target in the same tree:

```bash
# run from: firmware/
PATH="..." DTC_FLAGS=-@ make -C "$SRC/linux" ARCH=arm \
  CROSS_COMPILE=arm-linux-gnueabihf- zynq-pluto-sdr-fishball.dtb
cp src/linux/arch/arm/boot/dts/zynq-pluto-sdr-fishball.dtb output/devicetree.dtb
```

## Kernel options

On `firmware/`, configuration comes from `arch/arm/configs/zynq_pluto_defconfig`,
applied by `build_all.sh` at the start of **every** full build — so a
`menuconfig` change is a scratch edit. To keep it, edit the defconfig (and ship
it as a patch) or use `make savedefconfig`.

On `firmware-modern/` it comes from `fishball_defconfig`, which
`firmware-modern/setup.sh` installs and which CI checks still round-trips through
`savedefconfig`. **Do not build `zynq_pluto_defconfig` there**: ADI's defconfig
describes an ADALM-Pluto, which has no Ethernet, no SD card and boots from QSPI.
The first boot of that kernel came up perfectly and had none of the three.
`firmware-modern/config/fishball.config` lists the 26-option delta with a note
on which part of this board needs each one.

```bash
# run from: firmware/
PATH="..." make -C src/linux ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- menuconfig
```

`CONFIG_IKCONFIG`/`CONFIG_IKCONFIG_PROC` are on, so `zcat /proc/config.gz` on
the board reports exactly what it was built with — that is how this repo's
kernel was proved identical to the factory one.

| Option | Why you would touch it |
|---|---|
| `CONFIG_AD9361` | the transceiver driver — already `y` |
| `CONFIG_CF_AXI_ADC` / `CONFIG_CF_AXI_DDS` | capture and playback behind `cf-ad9361-lpc` and `cf-ad9361-dds-core-lpc` |
| `CONFIG_IIO_BUFFER` / `CONFIG_IIO_KFIFO_BUF` | the buffered-capture machinery every streaming tool needs |
| `CONFIG_DYNAMIC_DEBUG` | turns the drivers' `dev_dbg` on at runtime — invaluable, off by default |
| `CONFIG_FTRACE` / `CONFIG_KPROBES` | effectively **off on both kernels**, which is why `dump_stack()` + `dmesg` is the tracing tool of last resort. 6.12 compiles the ftrace framework in (`CONFIG_FTRACE=y`, a side effect of `CONFIG_DEBUG_KERNEL`), but without `CONFIG_FUNCTION_TRACER` the only tracer on the board is `nop` — checked, not assumed. `trace_marker` does work, which is enough to timestamp from userspace. The architecture supports the real thing, so enable it for a debug build if printk isn't enough |

## Debugging a driver change

The board runs busybox, so some habits do not transfer:

- **No ftrace, no kprobes.** A `dev_warn()` plus `dump_stack()` read back with
  `dmesg` is the substitute — and the `Comm:` line names the *process*, often
  the whole answer. It was here once: a transmit attenuation that appeared to
  reset itself turned out to be a userspace script.
- **No `pkill`** — `ps` and `kill` with a PID. Worth taking seriously: a test of
  the starvation watchdog that used `pkill` reported the watchdog broken. The
  writer had simply never been killed, so the watchdog kept being re-armed and
  was working perfectly. `pkill` is absent, and absent with `2>/dev/null` on it
  is silent.
- **An empty `dmesg` is information.** The kernel is not doing what you
  suspect; look in userspace or `/mnt/jffs2`.
- **`/sys/kernel/debug/iio/iio:device0/`** exposes the AD9361's BIST, every
  `adi,*` device-tree value, and `calib_mode`.

## Transmitter safety attributes

Four knobs the patched driver adds. All are readable, and all report what the
radio actually holds rather than what you asked for.

| Attribute | Device | Default | What it does |
|---|---|---|---|
| `tx_starve_timeout_ms` | `iio:device2` | `250` | Mute if the DAC gets no data for this long. `0` disables. Values under 20 ms are refused — this board's network path delivers in bursts and a shorter timeout would mute healthy streams. |
| `tx_cyclic_timeout_ms` | `iio:device2` | `0` (off) | Bound an unattended **cyclic** transmit, which otherwise repeats forever in hardware. |
| `tx_disable` | `iio:device0` | `0` | Latch maximum attenuation. Survives debugfs `initialize`, and blocks `bist_tone` mode 1. |
| `tx_temp_limit` | `iio:device0` | `0` (off) | Millidegrees C. Refuse to *lower* attenuation above this die temperature. |

Two counters, on `iio:device2`, which write-to-reset:

| Attribute | What it counts |
|---|---|
| `tx_dma_underflow_count` | the DAC ran out of data |
| `tx_dma_overflow_count` | the DMA could not keep up |

```bash
# run on the board
cd /sys/bus/iio/devices/iio:device2
cat tx_starve_timeout_ms tx_dma_underflow_count
echo 0 > tx_dma_underflow_count      # any write resets it
```

Why these exist, and what was measured:
[transmitter safety](transmitter-safety.md) and
[`tools/IDLE-CASES.md`](../tools/IDLE-CASES.md).

## Making it stick

Both `src/` directories are regenerated by their `setup.sh`, so a change survives
only as a patch. Generate it against the applied tree, number it after the
existing patches, and add an assertion to CI — every existing patch has one:

| target | patches go in | assertion goes in |
|---|---|---|
| `firmware/` | `firmware/patches/` | `.github/workflows/verify-patches.yml` |
| `firmware-modern/` | `firmware-modern/patches/` | `.github/workflows/verify-modern.yml` |

`CONTRIBUTING.md` has the details. Two things the modern workflow can check that
the other cannot, because a kernel needs no Vivado: it **builds the device tree
and audits it** (`firmware-modern/verify_dtb.py`, 16 checks on the compiled
`.dtb` — both device-tree bugs found during bring-up were invisible in the
`.dts` and both would have booted), and it **cross-builds `uImage`** and fails on
a warning in any file this repo patches.

Back to [Building your own firmware](building.md#change-the-kernel).
