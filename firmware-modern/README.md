# firmware-modern — a current Linux for this board

**Status: running on the board. All nine driver patches measured on hardware,
including one the re-test made necessary. RF loopback: 32 passed, 0 failed.**

| | |
|---|---|
| Linux 6.12.0 on the board | yes |
| `./devkit selftest --ssh` | **23 passed, 0 warnings, 0 failed** |
| `./devkit selftest --loopback --pad 20`, TX0→RX0 | **32 passed, 1 warning, 0 failed** |
| `./devkit gpio-check` | **PASS** — four pins, timing within 0.1% |
| cyclic transmit (`OPEN … CYCLIC`) | **works** — the loopback tone passes |
| Ethernet, SD card, GPIO sysfs | yes |
| the four GPIO lines resolve by name | yes — libgpiod line 72 on `gpiochip0`, as on 5.15. Resolve them by **chip label**, not with `gpiofind`: the Debian rootfs does not install libgpiod-tools, so `gpiofind`, `gpioinfo`, `gpioget` and `gpiodetect` are all absent there |
| transmitters at boot | **−89.75 dB**, from the device tree alone |
| `tools/flash.sh` over the network | works — `./devkit flash --target modern` |
| the driver patches | **nine**: eight rebased, one new — see [`patches/`](patches/) |
| the seven transmitter-safety attributes | all present, all reading their 5.15 values |
| CI | [`verify-modern.yml`](../.github/workflows/verify-modern.yml) — patches, built device tree, cross-built kernel |
| from a clean clone | `setup.sh` 1m27s, `uImage` 2m46s, device-tree audit 16/16 |

The one warning is [`patches/0015`](patches/) doing its job: the selftest set
61.75 dB of attenuation, its stream starved, and the driver muted underneath it.

This is the **recommended** firmware target — the one to use unless you
specifically want the factory kernel. The bare `./devkit` verbs still act on
[`firmware/`](../firmware/README.md), the target with the byte-for-byte
provenance claim and the one that builds the bitstream; **add `--target modern`**
and `setup`, `build`, `verify`, `flash`, `doctor`, `status` and `write-card` act
on this one instead ([issue #9](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/9)).
Building it is the short sequence below. Built for
[issue #4](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/4).
[`firmware/`](../firmware/README.md) stays as it is and stays buildable: a
verified, byte-identical reconstruction of the factory firmware. This is a
different thing that does not pretend to be that.

| | [`firmware/`](../firmware/README.md) | here |
|---|---|---|
| kernel | 5.15.0, vendor fork of a fork | **6.12.0**, Analog Devices `main` |
| device tree | 1003-line flat file, decompiled from the factory `.dtb` | **228-line overlay** on ADI's `zynq-pluto-sdr.dtsi` |
| userspace | Buildroot, busybox, ramdisk | **Debian 13 trixie armhf + systemd** on ext4 — [built and running](debian/README.md) |

## Why ADI 6.12 and not mainline 7.2

The issue proposed mainline. Mainline does not carry the AD9361 driver, and
that is the smaller half of the problem. `IIO_BUFFER_BLOCK_FLAG_CYCLIC` is
defined in `include/linux/iio/buffer_impl.h` — an ADI modification to **IIO
core** — and the board's libiio (pinned at `38483f31`, 0.25) probes
`BLOCK_FREE_IOCTL` to enable the high-speed path, where *"cyclic mode is only
supported"*. Without that ABI, libiio silently falls back to `read()/write()`
and **`OPEN … CYCLIC` stops working at the daemon**, which breaks
`./devkit gpio-check`, the selftest's loopback tone and the MCP's transmit
tools.

ADI's `main` is on 6.12 — a current LTS — and still ships `ad9361.c`,
`cf_axi_dds.c`, `cf_axi_adc_core.c` *and* that flag. So the eight
transmitter-safety patches rebase instead of being rewritten, and ~18,900 lines
stay someone else's job. Mainline remains a later stretch goal, not a
prerequisite.

## The device tree

`dts/zynq-pluto-sdr-fishball.dts` is an overlay, not a flat tree. The board's
AD9361 differs from a stock Pluto in exactly **nine properties**, established
by parsing both trees and diffing them rather than by eye: 2R2T, four LVDS
interface settings, two synthesiser start frequencies, a transmit feedback
clock delay, and the transmit attenuation.

That last one is safety-critical and is now a **default rather than a patch**.
ADI ships 10 dB; on a board with a power amplifier that is roughly +9 dBm out
of an SMA, applied by `ad9361_setup()` before any userspace runs. `main` fixes
it with patch 0011. Here it is simply the value in the tree, which is strictly
better — a patch can be forgotten.

Two bugs were caught by checking the built `.dtb` rather than trusting a clean
build, and both would have booted:

- a `memory@0` node became a **sibling** of the dtsi's `memory`, so the tree
  carried both 512 MB and 1 GB. `dtc` reported it only as an oblique
  "duplicate unit-address" warning against an unrelated node.
- `adi,channels` was missing. `dma-axi-dmac.c` configures from hardware only
  for cores `>= 4.3.a`; older ones take `axi_dmac_parse_dt()`, which returns
  `-ENODEV` without it. This board's bitstream is from ADI's 2018-era HDL, so
  a failed DMA probe — nothing streaming at all — was a real possibility.

## Building

```bash
# run from: the repo root
./devkit setup --target modern      # ADI's kernel with the patches, AND the boot side:
                                    # U-Boot, embeddedsw, bootgen (the boot side:
                                    # ~0.3 GB, ~20 s; the kernel clone is extra).
                                    # No Buildroot, no vendor 5.15 kernel.
./devkit build --target modern --xsa firmware/src/hdl/projects/pluto/system_top.xsa
./devkit verify --target modern     # BOOT.bin's partitions, read back out of it
```

That writes `output/BOOT.bin`, `uImage`, `devicetree.dtb` and `uEnv.txt`.
**`--xsa` is required**: this target has no Vivado path, and the FPGA design comes
only from an XSA. The path above exists only after a factory build
(`./devkit build`, which needs Vivado). Without Vivado, take the `system_top.xsa`
attached to a factory release — `./firmware-modern/fetch-pinned-xsa.sh` downloads
the one [`factory-xsa.pin`](factory-xsa.pin) names and checks its sha256 —
knowing that a release's XSA is *that release's* design. None published so far
matches a current from-source build, which is why there is no default: a silent
one would build a different FPGA.

Given the same XSA, `BOOT.bin` here is the factory target's, rebuilt: the same
FSBL, the same bitstream, the same U-Boot source, from the same pins
(`firmware/scripts/fetch_common.sh`). Checked against a board running the factory
build: the FSBL and bitstream partitions are byte-identical, and U-Boot differs
only inside its build-date string.

**No ARM Linux cross-compiler on this machine?** The build container has one —
put `container` in front, and nothing else changes:

```bash
# run from: the repo root
./devkit container build --target modern --xsa firmware/src/hdl/projects/pluto/system_top.xsa
```

Then onto a running board, over the network, with a backup and an md5 check
before anything is swapped — just the files you mean to change:

```bash
# run from: the repo root
./devkit flash --target modern --boot-only       # BOOT.bin
./devkit flash --target modern --kernel-only     # uImage
./devkit flash --target modern --dtb-only        # devicetree.dtb
```

`--all` and `--rootfs-only` are refused here: this target's root is Debian on the
card's second partition, not a file on `/boot`. A whole card, from a reader:

```bash
# run from: the repo root
./devkit write-card --target modern --dry-run /dev/sdX   # the device checks, nothing written
sudo ./devkit write-card --target modern /dev/sdX        # refuses any non-removable disk
```

`build_all.sh` runs these steps, and they still work by hand:

```bash
# run from: firmware-modern/src/linux
CROSS=arm-linux-gnueabihf-          # any ARM Linux GCC; see the note below
make ARCH=arm CROSS_COMPILE=$CROSS fishball_defconfig
make ARCH=arm CROSS_COMPILE=$CROSS uImage LOADADDR=0x8000 -j$(nproc)
make ARCH=arm CROSS_COMPILE=$CROSS DTC_FLAGS=-@ xilinx/zynq-pluto-sdr-fishball.dtb
```

**`CROSS` can be any ARM Linux toolchain** for the kernel — `apt install
gcc-arm-linux-gnueabihf` is enough for it, and CI builds the kernel this way.
**U-Boot is different: it needs the soft-float `arm-linux-gnueabi`** (the
hard-float one fails on U-Boot's ARMv5 objects), so a whole `./devkit build
--target modern` needs `gcc-arm-linux-gnueabi` — which the build container has.
The container builds the kernel with that soft-float compiler too, which the
kernel does not mind: it uses no floating point. That gives a different binary
from an armhf build (the payload came out 18.5 KB smaller) from the same source
and the same release string — and **that soft-float kernel has not yet been booted
on hardware**; the board runs an armhf one. It does not have to be
the Linaro 7.3 that `firmware/`'s Buildroot produces: that path
(`../../../firmware/src/buildroot/output/host/bin/arm-linux-gnueabihf-`) only
exists after a full 45–90 minute build of the *other* target, which you do not
need. 6.12 builds with both.

**Do not build `zynq_pluto_defconfig` on its own.** It rebuilds boot 1 from the
table below: no Ethernet, no SD card, no GPIO sysfs. ADI's defconfig describes an
ADALM-Pluto, and a Pluto has none of that hardware.

Two config files, doing different jobs:

| | |
|---|---|
| [`config/fishball_defconfig`](config/fishball_defconfig) | what to **build**. 266 lines, `savedefconfig` output, verified to reproduce the `.config` that built the tested `uImage` byte-for-byte. Sixteen lines more than `zynq_pluto_defconfig`. |
| [`config/fishball.config`](config/fishball.config) | why each option is there — 26 entries, annotated with which part of this board needs it. Four of them (`ETHERNET`, `OF_MDIO`, `DEBUG_KERNEL`, `CRYPTO_ECB`) do not appear in the defconfig because they are implied; `savedefconfig` strips anything Kconfig will select anyway. |

Keeping both is deliberate: a `defconfig` is reproducible but says nothing, and
a commented delta explains itself but drifts. The defconfig is authoritative.

The `.dts` is built by name because nothing adds it to a Makefile; that is
deliberate, so the file stays a drop-in rather than a tree modification.

`zynq_pluto_defconfig` already enables `CONFIG_AD9361`, `CONFIG_CF_AXI_ADC` and
`CONFIG_CF_AXI_DDS`. The 2018-era Linaro GCC 7.3 from `main`'s Buildroot builds
6.12 without complaint.

## What the bring-up cost, and what it taught

Three boots, two card-reader trips. Every failure was the same shape: **ADI's
`zynq_pluto_defconfig` and `zynq-pluto-sdr.dtsi` describe an ADALM-Pluto**, and
this board is a Pluto-compatible with more hardware on it. Nothing was wrong
with the kernel; things were simply absent.

| boot | what was missing | why |
|---|---|---|
| 1 | Ethernet, SD, GPIO sysfs | `CONFIG_MACB`, `CONFIG_REALTEK_PHY`, `CONFIG_MMC`, `CONFIG_GPIO_SYSFS` — a Pluto has no Ethernet and boots from QSPI |
| 2 | SD only | driver built, but ADI's dtsi says `&sdhci0 { status = "disabled"; }` |
| 3 | nothing | — |

Two lessons worth keeping:

- **Losing `/dev/mmcblk0` costs a card-reader trip**, because `tools/flash.sh`
  works by mounting `/dev/mmcblk0p1` on the running board. It is the one
  capability whose absence you cannot fix remotely.
- **The USB gadget saved both rounds.** With Ethernet down the board was still
  reachable at `192.168.2.1`, which is how every measurement above was taken.
  Keep the USB cable connected while iterating on the kernel.

After boot 2 the guessing stopped: comparing the `status` of every node in the
built `.dtb` against the factory one found exactly one regression, and after
the fix, none. That audit is cheap and worth re-running on any DTS change.

## The driver patches

All nine are applied in filename order and measured on the board
rather than declared to apply. [`patches/README.md`](patches/README.md) has the
per-patch detail; the short version:

- **six of the eight rebased patches add byte-for-byte identical code.** Only
  `0004` and `0015` needed anything different, and both times because ADI's tree
  changed, not because the patch was fragile.
- re-testing them on hardware found a **safety hole that predates this branch**:
  `clear_state()` memset the attenuation that the kernel's unmute restores, so a
  debugfs `initialize` followed by any transmit stream keyed the transmitter flat
  out. Measured, with an antenna fitted. `0019` fixes it; the same code is on
  `main`.
- the rebase **found an upstream bug**: ADI's 6.12 never wires up
  `indio_dev->setup_ops`, so the DDS buffer's pre-enable and post-disable hooks
  are dead. gcc warns about it. `0004` restores the line.
- the **buildroot halves of `0004` and `0012` are not carried here**, because
  `main`'s rootfs already has them. That becomes a live trap the moment the
  rootfs is replaced — see the README in `patches/`.

## Next

**Debian is done and running** — [`debian/`](debian/README.md) builds the root and
writes a card; the reasoning is in
[`docs/debian-rootfs.md`](../docs/debian-rootfs.md).
Shorter than it looks: U-Boot needs no rebuild because `uEnv.txt` is imported into
its environment and `sdboot` is defined there; it needs no ext4 support either,
because the kernel mounts the root; the kernel is two defconfig lines short of
what systemd wants; and `iiod` can be carried across unchanged, which removes the
cyclic-ABI risk that would otherwise decide the whole thing.

Throughput and signal parity are **done** — see above and
[`docs/measured-performance.md`](../docs/measured-performance.md).

## The IIO contract, 5.15 against patched 6.12

`dump_context.py` dumps every device, channel and attribute as a sorted,
diffable list, so "the contract holds" is a `diff` rather than a judgement. The
whole residual delta is nine lines:

| | |
|---|---|
| **added** | `waiting_for_supplier` on all four devices — IIO driver core, not ours |
| **added** | `adi,agc-dig-sat-ovrg-enable`, a new AD9361 debug attribute |
| **removed** | four `label` channel attributes on `cf-ad9361-lpc` |

All seven transmitter-safety attributes are present and read their 5.15 values.

The four missing labels looked like the one thing left unexplained, and the
explanation turns out to be that **5.15 was the broken one**. Up to 5.15,
`axiadc_read_label()` used the converter's `read_label` if it had one and
otherwise fell back to `chan->extend_name`; `ad9361_conv.c` supplies no
`read_label` and the ADC's voltage channels have no `extend_name`, so the
fallback returned `-ENOSYS`. The files existed and could not be read. ADI's 6.12
replaced the wrapper with `axiadc_info.read_label = conv->read_label`, so with a
NULL callback the attribute is simply never created. Nothing to fix: an attribute
that always fails is worse than one that is absent.

## When a kernel does not boot

`tools/flash.sh` is the good route — over the network, backed up and md5-verified
before it swaps anything, with the previous file kept on the card as `*.prev`. It
works by mounting `/dev/mmcblk0p1` **on the running board**, which means it needs
the board's own kernel to have an MMC driver and to have booted far enough to run
`sshd`. A kernel that does not boot removes that route entirely.

`./firmware-modern/write_card.sh` is the way back, from a card reader on this
machine:

```bash
# run from: the repo root, card in a reader
./firmware-modern/write_card.sh            # uImage + devicetree.dtb
./firmware-modern/write_card.sh --restore   # put main's 5.15 files back
```

It will not overwrite an existing `*.prev`. That is deliberate and it is the
opposite of what `flash.sh` does: `flash.sh` rolls `.prev` forward, which is right
when every version booted, but here the copy on the card may be a kernel that
does not. The first known-good file is the one worth keeping.

Two boots of the 6.12 bring-up needed this, both for the same reason — ADI's
defconfig and dtsi describe an ADALM-Pluto, which boots from QSPI and has no SD
card at all, so `CONFIG_MMC` was off and then `&sdhci0` was `disabled`. **Losing
`/dev/mmcblk0` is the one capability whose absence you cannot fix remotely**, and
it is now asserted by `verify_dtb.py` and by CI for that reason.

The USB gadget saved both rounds: with Ethernet down the board still answered at
`192.168.2.1`. Keep the USB cable connected while iterating on a kernel.

## Throughput, and a measurement that measures itself

Receive throughput on the board, no network involved — `iio_readdev -b 1048576`,
sample rate 61.44 MS/s, three repeats, measured 2026-09-27 on 6.12:

| samples per run | 1 receive channel | 2 receive channels |
|---|---|---|
| 33.6 M (the method [`docs/img/data/throughput.json`](../docs/img/data/throughput.json) records) | 183.1 MB/s · 48.0 MS/s/ch | 346.4 MB/s · 45.4 MS/s/ch |
| **134.4 M** (4× longer) | **220.0 MB/s · 57.7 MS/s/ch** | **430.8 MB/s · 56.5 MS/s/ch** |
| recorded for 5.15 | 199.3 MB/s · 49.8 MS/s/ch | 369.4 MB/s · 46.2 MS/s/ch |

**The same kernel measures 20% differently depending on how long the run is**,
and that is the first finding. `iio_readdev`'s process start and its buffer
allocation sit inside the timed window, so at 33.6 Msamples — 0.7 s — the fixed
cost is a sixth of the measurement. At 2.33 s it is negligible.

The second is the answer to the question that raised: **the kernel makes no
difference.** Interleaved 6.12 → 5.15 → 6.12, reflashing between rounds, same
method throughout:

| | 33.6 M, 1 ch | 33.6 M, 2 ch | 134.4 M, 1 ch | 134.4 M, 2 ch |
|---|---|---|---|---|
| 6.12 | 183.1 | 346.4 | 220.0 | 430.8 |
| 5.15 | 183.1 | 346.4 | 220.0 | 430.8 |
| 6.12 again | 183.1 | 341.8–346.4 | 220.0 | 429.0–430.8 |

MB/s. Every figure matched, and the scatter *within* a kernel is larger than any
difference *between* them — so the 7% shortfall the short run appeared to show
was the measurement, not the software. Stage 3 of the modernisation plan is
closed by this table.

Re-run it with [`../tools/throughput-ab.sh`](../tools/throughput-ab.sh), which
exists so the method cannot drift between one kernel and the next.

## Reproducibility

A clean clone gives the same device tree and the same drivers, and that is
checked: `firmware-modern/verify_dtb.py` passes 16/16 on a `.dtb` built from a
fresh `setup.sh`, and CI does it on every push.

The `uImage` **is** byte-reproducible, but not by default, and the two things
that stop it are worth knowing because one of them is not the kernel's:

```bash
# run from: firmware-modern/src/linux - two clean builds of this give one md5
export KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 2026"
export KBUILD_BUILD_USER=devkit KBUILD_BUILD_HOST=devkit KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=1767225600
```

Measured, four clean builds in a fresh clone:

| pinned | result |
|---|---|
| nothing | differs — the kernel puts `git describe`, the builder's user and host, a build counter and a timestamp in `UTS_VERSION` |
| `KBUILD_BUILD_*` only | **the kernel payload is byte-for-byte identical.** Two builds differed in exactly six bytes, all inside the 64-byte U-Boot header: `ih_time` and the `ih_hcrc` that covers it |
| `KBUILD_BUILD_*` + `SOURCE_DATE_EPOCH` | **identical files** |

That middle row is `mkimage` stamping the current time, and it is the *same*
defect this repo already found in `uramdisk.image.gz` — where the payload was
always identical and only the header moved, and where
`firmware/scripts/build_all.sh` fixed it with `SOURCE_DATE_EPOCH` for exactly this
reason. `mkimage` honours that variable for a `uImage` too.

Nothing here pins them by default: a build timestamp that always reads
1 January is a real loss when you are trying to work out which kernel is on a
card. Pin them when you want to compare two builds, which is the only time the
question comes up.

## Still owed upstream

The `setup_ops` finding in `patches/0004`. Same shape as the label change — a
refactor that dropped a fallback — but this one has teeth, because the hooks it
silently disabled are where transmit muting lives.
