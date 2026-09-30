# The modern kernel: Linux 6.12 on this board

Background for [`firmware-modern/`](../firmware-modern/README.md): why this
kernel, what differs from the factory 5.15, and how to check that nothing a
host tool depends on has changed. To build and flash it, start with that README.

## Why ADI 6.12, and not mainline

Mainline Linux does not carry the AD9361 driver, but that is the smaller
problem. **Cyclic transmit** (the board repeating one buffer forever, which
`./devkit gpio-check`, the self-test's loopback tone and the MCP server's
transmit tools all use) depends on `IIO_BUFFER_BLOCK_FLAG_CYCLIC`. That flag is
defined in `include/linux/iio/buffer_impl.h`, an Analog Devices change to the
IIO core. The board's libiio (0.25, pinned at `38483f31`) probes the matching
`BLOCK_FREE_IOCTL` to enable its high-speed path, and cyclic mode exists only
there. Without that interface libiio falls back to plain `read()`/`write()`
and `OPEN … CYCLIC` fails at the daemon, with nothing in the kernel log.

ADI's `main` branch is on 6.12, a long-term-support kernel, and still ships
`ad9361.c`, `cf_axi_dds.c`, `cf_axi_adc_core.c` and that flag. So the
transmitter-safety patches rebase rather than being rewritten, and about 18,900
lines of driver code stay upstream's to maintain. Mainline stays a later goal.

## The device tree

`dts/zynq-pluto-sdr-fishball.dts` is an **overlay** on ADI's
`zynq-pluto-sdr.dtsi`: it states only where this board differs from an
ADALM-Pluto. The AD9361 node differs in nine properties, found by parsing and
diffing both trees: 2R2T mode, four LVDS interface settings, two synthesiser
start frequencies, a transmit feedback clock delay, and the transmit
attenuation.

The attenuation is a safety setting. ADI's default is 10 dB, which on this
board is roughly +9 dBm out of the SMA connector, applied by `ad9361_setup()`
before any userspace runs. The tree sets `adi,tx-attenuation-mdB = 89750`
instead, so the transmitter comes up at −89.75 dB without needing a patch.

Check the **built** `.dtb`, not just the build log. Two mistakes of this kind
boot fine and are only visible in the output:

- A `memory@0` node written as a sibling of the dtsi's `memory` node gives the
  kernel two memory sizes. `dtc` only warns about a "duplicate unit-address".
- Without `adi,channels`, the DMA driver fails to probe on this board's
  2018-era FPGA cores (`dma-axi-dmac.c` reads the configuration from hardware
  only for cores `>= 4.3.a`), and nothing streams.

`firmware-modern/verify_dtb.py` checks the built tree, including that every
node the factory tree enables is still enabled. CI runs it on every push.

## Why `zynq_pluto_defconfig` alone does not work

ADI's `zynq_pluto_defconfig` and `zynq-pluto-sdr.dtsi` describe an ADALM-Pluto.
A Pluto boots from QSPI flash and has no Ethernet and no SD card, so they leave
out what this board needs:

| missing | effect | fixed by |
|---|---|---|
| `CONFIG_MACB`, `CONFIG_REALTEK_PHY` | no Ethernet | `config/fishball_defconfig` |
| `CONFIG_MMC` | no SD card | `config/fishball_defconfig` |
| `CONFIG_GPIO_SYSFS` | no GPIO sysfs | `config/fishball_defconfig` |
| `&sdhci0 { status = "disabled"; }` in the dtsi | no SD card, even with the driver built | the board's `.dts` |

Losing the SD card is the expensive one. `tools/flash.sh` works by mounting
`/dev/mmcblk0p1` on the running board, so a kernel without it cannot be
replaced over the network; the card has to come out. `verify_dtb.py` and CI
assert the SD controller is enabled for that reason.

The config lives in two files with different jobs:

| | |
|---|---|
| [`config/fishball_defconfig`](../firmware-modern/config/fishball_defconfig) | what to build: `savedefconfig` output, and the authoritative one |
| [`config/fishball.config`](../firmware-modern/config/fishball.config) | why each option is there, one annotated entry per option. Some options (`ETHERNET`, `OF_MDIO`, `DEBUG_KERNEL`, `CRYPTO_ECB`) appear only here, because Kconfig selects them and `savedefconfig` drops anything implied |

The `.dts` is built by name (`make … xilinx/zynq-pluto-sdr-fishball.dtb`) and is
not added to any Makefile, so it stays a drop-in file rather than a change to
ADI's tree.

## The driver patches

Nine patches in [`firmware-modern/patches/`](../firmware-modern/patches/README.md),
applied in filename order; that README has the detail for each.

- Eight are rebased from the factory target. Six add the same code as before;
  `0004` and `0015` differ because ADI's tree changed around them.
- `0019` is new. `clear_state()` cleared the attenuation that the kernel's
  unmute restores, so a debugfs `initialize` followed by a transmit stream
  transmitted at full power. The same fix is on the factory target.
- ADI's 6.12 never sets `indio_dev->setup_ops`, so the DDS buffer's pre-enable
  and post-disable hooks, where transmit muting lives, never run. gcc warns
  about it. `0004` restores the line. This should go upstream.
- The Buildroot halves of `0004` and `0012` are not carried: the Debian root
  replaces Buildroot. See the patches README for what that means if you swap
  the root filesystem.

## The IIO contract against 5.15

`firmware-modern/dump_context.py` lists every IIO device, channel and attribute
as a sorted text file, so comparing two kernels is a `diff`. Between 5.15 and
the patched 6.12 the whole difference is:

| | |
|---|---|
| added | `waiting_for_supplier` on all four devices (driver core) |
| added | `adi,agc-dig-sat-ovrg-enable`, a new AD9361 debug attribute |
| removed | four `label` channel attributes on `cf-ad9361-lpc` |

All seven transmitter-safety attributes are present and read their 5.15 values.

The removed labels could never be read. On 5.15, `axiadc_read_label()` fell
back to `chan->extend_name`, which these channels do not have, so reading the
file returned `-ENOSYS`. On 6.12 the attribute is only created when the
converter supplies a `read_label` callback, and `ad9361_conv.c` does not.

## Receive throughput

On the board, no network involved: `iio_readdev -b 1048576` at 61.44 MS/s.

| samples per run | 1 receive channel | 2 receive channels |
|---|---|---|
| 33.6 M | 183.1 MB/s | 346.4 MB/s |
| 134.4 M | 220.0 MB/s (57.7 MS/s) | 430.8 MB/s (56.5 MS/s per channel) |

5.15 and 6.12 give the same figures, run interleaved on the same board with
the same method. The run length matters more than the kernel: `iio_readdev`'s
start-up and buffer allocation are inside the timed window, and at 33.6 M
samples (0.7 s) that fixed cost is a sixth of the measurement. Use long runs,
and use [`tools/throughput-ab.sh`](../tools/throughput-ab.sh) to compare two
kernels so the method stays the same.

## Reproducible builds

A clean clone gives the same device tree, and CI checks it. The `uImage` can be
byte-for-byte reproducible, but it is not by default, because the kernel and
`mkimage` both stamp the build time. Pin these to compare two builds:

```bash
# run from: firmware-modern/src/linux
export KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 2026"
export KBUILD_BUILD_USER=devkit KBUILD_BUILD_HOST=devkit KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=1767225600
```

| pinned | result |
|---|---|
| nothing | differs: `UTS_VERSION` carries `git describe`, user, host, a build counter and a timestamp |
| `KBUILD_BUILD_*` only | the kernel is identical; six bytes of the 64-byte U-Boot header differ (`ih_time` and its checksum) |
| `KBUILD_BUILD_*` and `SOURCE_DATE_EPOCH` | identical files |

They are not pinned by default, because a real build time is how you tell which
kernel is on a card.
