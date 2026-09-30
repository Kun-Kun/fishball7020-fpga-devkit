# Changing the kernel

The FPGA is half the board. The other half is a Linux kernel with Analog
Devices' (ADI's) drivers in it, and much of the board's *behaviour* (what
appears in `/sys`, when the transmitter is muted, what the serial number is)
lives there, not in the fabric. This page covers both kernels: which to use,
what is already patched, the two-minute rebuild loop, the options that matter,
debugging a driver, and making a change stick.

Four terms:

- **the kernel** is Linux itself, built as one file (`uImage`);
- **a driver** is the kernel code operating a device (here: the AD9361 and the
  FPGA's capture and playback blocks);
- **the device tree** (`devicetree.dtb`) is a data file describing what hardware
  exists and where, compiled from a `.dts` source file;
- **a defconfig** is a saved set of build options.

You are **cross-compiling** (building on your PC for the board's ARM cores),
hence `ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-` everywhere.

> **`gnueabi` or `gnueabihf`.** Either ARM Linux compiler builds the kernel and,
> through `./devkit build`, U-Boot. On the factory target prefer
> `sudo apt install gcc-arm-linux-gnueabi`: only it rebuilds the factory kernel
> byte for byte. Building U-Boot by hand with `gnueabihf` needs
> `CC="arm-linux-gnueabihf-gcc -mfloat-abi=soft"`; see
> [troubleshooting](troubleshooting.md).

> **Not sure the kernel is where your change belongs?**
> [Using this board in your own project](your-own-project.md) compares the four
> places code can live here (your PC, the board's userspace, the kernel, the
> fabric) and the iteration time of each. Most projects want the first one. The
> course's **lesson 23** covers the kernel/fabric boundary from the other side:
> [Fabric School](course/index.html).

## Which kernel

| | `firmware/` | `firmware-modern/` |
|---|---|---|
| Linux | **5.15.0**, the vendor's fork of a fork | **6.12.0 LTS**, Analog Devices' `main` |
| source appears at | `firmware/src/linux` (one flattened monorepo with U-Boot and Buildroot beside it) | `firmware-modern/src/linux` (just the kernel) |
| created by | `./devkit setup` | `./firmware-modern/setup.sh` |
| device tree | `arch/arm/boot/dts/zynq-pluto-sdr-fishball.dts`, 1003 lines, flat | `arch/arm/boot/dts/xilinx/zynq-pluto-sdr-fishball.dts`, 228 lines, an overlay on ADI's `zynq-pluto-sdr.dtsi` |
| defconfig | `zynq_pluto_defconfig` | `fishball_defconfig` |
| patches | `firmware/patches/`, 18 of them | `firmware-modern/patches/`, nine, drivers only |

**Use `firmware-modern/` unless you specifically need the factory kernel.** It is
a current long-term-support kernel, its device tree is 228 lines rather than
1003, and the transmitter-safety patches are on it, tested on hardware.
`firmware/` exists because the byte-identical factory claim is only meaningful
against the factory kernel. [Why 6.12 and not
mainline](modern-kernel.md#why-adi-612-and-not-mainline).

Everything below applies to both unless it says otherwise. What differs is
mostly where files are, and that a 6.12 driver change is a patch in
`firmware-modern/patches/` rather than in `firmware/patches/`.

## What is already patched

A few of the factory target's patches, as examples (the full list with a
section on each is [`firmware/patches/README.md`](../firmware/patches/README.md)):

| Patch | Touches | Does |
|---|---|---|
| `0001-fishball7020-fixes.patch` | buildroot scripts | six upstream fixes; mints a persistent `hw_serial` on first boot |
| `0002-add-fishball-devicetree.patch` | `arch/arm/boot/dts/` | the board's device tree, as editable source |
| `0004-mute-tx-when-no-dma-stream.patch` | `drivers/iio/adc/ad9361.*`, `drivers/iio/frequency/cf_axi_dds*` | mutes the transmitter whenever no DMA buffer streams |
| `0005-dont-clobber-a-gain-set-before-streaming.patch` | the same two drivers | stops the unmute overwriting a gain you set before starting |

Reading these is the fastest way to see how a change here is structured; `0005`
is the smallest.

`firmware-modern/patches/` carries the transmitter-safety patches on 6.12:
`0004`, `0005`, `0007`, `0012`, `0015`, `0016`, `0017` and `0018` rebased, plus
`0019`, which exists only there. **Six of the eight rebased patches add
byte-for-byte identical code**, so reading either set teaches the other.
[The modern patches](../firmware-modern/patches/README.md).

`0019` fixes a case that also exists in the 5.15 code: `ad9361_clear_state()`
memsets the struct that held the attenuation the kernel restores when it
unmutes, and 0 mdB (millidecibels) of attenuation is full output. A debugfs
`initialize` followed by any transmit stream therefore keyed the transmitter at
full power. It is the third safety-relevant field moved out of that struct,
after `0016`'s latch and `0018`'s temperature limit. The rule that follows is in
[Making it stick](#making-it-stick).

## The build

`./devkit build` builds the kernel with everything else (stage 4), but while
iterating you want a two-minute cycle, not seventy.

**`firmware/`:**

```bash
# run from: firmware/
make -C src/linux -j"$(nproc)" ARCH=arm \
  CROSS_COMPILE=arm-linux-gnueabi- uImage UIMAGE_LOADADDR=0x8000
cp src/linux/arch/arm/boot/uImage output/uImage
```

The factory kernel is built with the distribution's cross-compiler, so
Buildroot's toolchain does not need to be on `PATH`, or to exist at all unless
you are rebuilding the root filesystem.

The device tree is a separate target in the same tree:

```bash
# run from: firmware/
DTC_FLAGS=-@ make -C src/linux ARCH=arm \
  CROSS_COMPILE=arm-linux-gnueabi- zynq-pluto-sdr-fishball.dtb
cp src/linux/arch/arm/boot/dts/zynq-pluto-sdr-fishball.dtb output/devicetree.dtb
```

**`firmware-modern/`:** the defconfig names everything and the tree is just a
kernel.

```bash
# run from: firmware-modern/src/linux
CROSS=arm-linux-gnueabi-      # or arm-linux-gnueabihf-
make ARCH=arm CROSS_COMPILE=$CROSS fishball_defconfig
make ARCH=arm CROSS_COMPILE=$CROSS uImage LOADADDR=0x8000 -j$(nproc)
make ARCH=arm CROSS_COMPILE=$CROSS DTC_FLAGS=-@ xilinx/zynq-pluto-sdr-fishball.dtb
cp arch/arm/boot/uImage ../../output/
# The rename is yours to do: tools/flash.sh looks for the literal name
# devicetree.dtb and aborts if it is missing.
cp arch/arm/boot/dts/xilinx/zynq-pluto-sdr-fishball.dtb ../../output/devicetree.dtb
```

Any ARM cross-compiler works: `gcc-arm-linux-gnueabi` from the distribution is
what `build_all.sh` prefers, and 6.12 builds equally well with the Linaro 7.3
that Buildroot fetches for the root filesystem. A kernel takes about two
minutes.

Then flash **`uImage` alone** (the other files have not changed) and reboot;
the board is back in about fifteen seconds:

```bash
# run from: the repo root
./devkit flash --kernel-only                  # firmware/
./devkit flash --target modern --kernel-only  # firmware-modern/
```

A changed device tree goes with `--dtb-only`.

## Kernel options

On `firmware/`, configuration comes from `arch/arm/configs/zynq_pluto_defconfig`,
which `build_all.sh` applies at the start of **every** full build, so a
`menuconfig` change is a scratch edit. To keep it, edit the defconfig (and ship
it as a patch) or use `make savedefconfig`.

```bash
# run from: firmware/
make -C src/linux ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- menuconfig
```

On `firmware-modern/` it comes from `fishball_defconfig`, which
`firmware-modern/setup.sh` installs and which CI checks still round-trips
through `savedefconfig`. **Do not build `zynq_pluto_defconfig` there.** It is
ADI's configuration for an ADALM-Pluto, which has no Ethernet, no SD card and
boots from QSPI flash; a kernel built from it boots cleanly and has none of the
three. `firmware-modern/config/fishball.config` lists the 26-option difference,
with a note on which part of this board needs each one.

`CONFIG_IKCONFIG` and `CONFIG_IKCONFIG_PROC` are on, so `zcat /proc/config.gz`
on the board reports exactly what the running kernel was built with. That is
how this repository's factory kernel configuration is shown identical to the
original ([provenance](provenance.md)).

| Option | Why you would touch it |
|---|---|
| `CONFIG_AD9361` | the transceiver driver: already `y` |
| `CONFIG_CF_AXI_ADC` / `CONFIG_CF_AXI_DDS` | capture and playback behind `cf-ad9361-lpc` and `cf-ad9361-dds-core-lpc` |
| `CONFIG_IIO_BUFFER` / `CONFIG_IIO_KFIFO_BUF` | the buffered-capture machinery every streaming tool needs |
| `CONFIG_DYNAMIC_DEBUG` | turns the drivers' `dev_dbg` messages on at runtime; off by default, and very useful |
| `CONFIG_FTRACE` / `CONFIG_KPROBES` | effectively **off on both kernels**. 6.12 compiles the ftrace framework in (`CONFIG_FTRACE=y`, a side effect of `CONFIG_DEBUG_KERNEL`), but without `CONFIG_FUNCTION_TRACER` the only tracer on the board is `nop`. `trace_marker` works, which is enough to timestamp from userspace. The architecture supports the full tracer, so enable it for a debug build if printk is not enough |

## Debugging a driver change

**Which userspace the board runs changes what is available.** The points below
are for the **factory** target (`firmware/`), which runs busybox. On
`firmware-modern/` (Debian 13, the recommended target) `pkill`, full `ps`,
`gdb` and anything else you `apt install` are available. The ftrace point
applies to both, because it is kernel configuration.

- **No ftrace, no kprobes.** Use a `dev_warn()` plus `dump_stack()` and read it
  back with `dmesg`. The `Comm:` line names the *process* that called in, which
  is often the whole answer: for example, a transmit attenuation that seems to
  reset itself can be a userspace script writing it.
- **No `pkill` on busybox.** Use `ps` and `kill` with a PID. A `pkill` with
  `2>/dev/null` on it fails silently, so the process you meant to stop keeps
  running, and a test built on it reports the wrong thing (a writer that was
  never killed keeps re-arming the starvation watchdog, which then looks
  broken).
- **An empty `dmesg` is information.** The kernel is not doing what you suspect;
  look in userspace, or in `/mnt/jffs2` (scripts there run at boot on
  Buildroot).
- **`/sys/kernel/debug/iio/iio:device0/`** exposes the AD9361's BIST (built-in
  self test), every `adi,*` device-tree value, and `calib_mode`.

## Transmitter safety attributes

Four settings the patched driver adds. All are readable, and all report what
the radio actually holds rather than what you asked for.

| Attribute | Device | Default | What it does |
|---|---|---|---|
| `tx_starve_timeout_ms` | `iio:device2` | `250` | Mute if the DAC gets no data for this long. `0` disables. Values under 20 ms are refused: this board's network path delivers in bursts, and a shorter timeout would mute healthy streams. |
| `tx_cyclic_timeout_ms` | `iio:device2` | `0` (off) in the driver, **`60000` on this devkit's root filesystem** | Bound an unattended **cyclic** transmit, which otherwise repeats forever in hardware. `fishball-rf-quiesce` arms it at boot; `fw_setenv tx_cyclic_bound <ms>` changes it, `0` disables. |
| `tx_disable` | `iio:device0` | `0` | Latch maximum attenuation. Survives debugfs `initialize`, and blocks `bist_tone` mode 1. |
| `tx_temp_limit` | `iio:device0` | `0` (off) | Millidegrees C. Refuse to *lower* attenuation above this die temperature. |

Two counters on `iio:device2`, reset by any write:

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

Why these exist, and the measurements behind them:
[transmitter safety](transmitter-safety.md) and
[`tools/IDLE-CASES.md`](../tools/IDLE-CASES.md).

## Making it stick

Both `src/` directories are regenerated by their `setup.sh`, so a change
survives only as a patch. Generate it against the applied tree, number it after
the existing patches, and add an assertion to CI (every existing patch has one):

| target | patches go in | assertion goes in |
|---|---|---|
| `firmware/` | `firmware/patches/` | `.github/workflows/verify-patches.yml` |
| `firmware-modern/` | `firmware-modern/patches/` | `.github/workflows/verify-modern.yml` |

**Never put a safety-relevant field in `struct ad9361_rf_phy_state`.**
`ad9361_clear_state()` memsets it, and debugfs `initialize` calls it, so anything
kept there can be cleared by the interface it is meant to defend against. Use
`struct ad9361_rf_phy`, and seed the field so that zero is not the dangerous
value.

[`CONTRIBUTING.md`](../CONTRIBUTING.md) has the details. The modern workflow
checks two things the factory one cannot, because a kernel needs no Vivado: it
**builds the device tree and audits it** (`firmware-modern/verify_dtb.py`, 16
checks on the compiled `.dtb`, because device-tree mistakes usually build
cleanly and boot), and it **cross-builds `uImage`** and fails on a warning in
any file this repository patches.

Back to [Building your own firmware](building.md#change-the-kernel).
