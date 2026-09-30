# Provenance: how close the rebuild is to the factory firmware

The board ships with no published, editable firmware source. This repository
reconstructs it from public sources. This page states what is claimed about
that reconstruction, what the evidence is, and how to check it yourself.

## Sources

- **The starting point:** the public upstream fork
  [`Xiaozhang-code-cloud/Fish-Wan-plutosdr-fw-7020-SDR`](https://github.com/Xiaozhang-code-cloud/Fish-Wan-plutosdr-fw-7020-SDR).
- **The board's schematic** ([`vendor/`](vendor/README.md)), against which the
  HDL project's pin constraints are checked by hand. Similarly named projects
  exist that compile cleanly but target *different* boards; the schematic is
  what tells them apart.
- **The distributor's prebuilt binaries,**
  [`OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR`](https://github.com/OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR).
  They match a real unit's SD card byte for byte, so they are the genuine
  factory firmware. They include no editable HDL or kernel source; none has been
  published.
- **The factory kernel's own configuration,** extracted from the factory
  `uImage` (the kernel is built with `CONFIG_IKCONFIG`, which embeds its
  `.config`).

## What is claimed for `firmware/`

Built from this source and compared file by file with a real factory unit's SD
card:

| File | Result |
|---|---|
| `devicetree.dtb` | patch `0002` recompiles byte for byte to the factory file. Two later patches change it on purpose: `0008` (GPIO line names) and `0011` (probe-time transmit attenuation) |
| `uEnv.txt` | the same content; only the order U-Boot dumps its variables in differs |
| root filesystem | the same file list |
| kernel `.config` | identical to the one extracted from the factory `uImage` |
| `uImage`, U-Boot | within a few hundred bytes of the originals, not identical: upstream's history was squashed *after* this board's firmware was built, so some source has drifted and cannot be recovered from public sources |

The [patch list](../firmware/patches/README.md) has each change, including two
upstream bugs.

### Checking it yourself

```bash
# run from: the repo root
./devkit verify --board          # is the card running what you built?
iio_info -u ip:fishball.local | grep -E 'fw_version|hw_model'

# against a devicetree.dtb from a factory SD card (FACTORY/): only
# gpio-line-names (0008) and adi,tx-attenuation-mdB (0011) should differ
diff <(dtc -I dtb -O dts FACTORY/devicetree.dtb) \
     <(dtc -I dtb -O dts firmware/output/devicetree.dtb)
```

```bash
# run on the board: the configuration the running kernel was built with
zcat /proc/config.gz
```

Compare that output from a factory board and from your build. More in
[`firmware/README.md`](../firmware/README.md) and
[Verify your build is actually running](flashing.md#verify-your-build-is-actually-running).

## What is claimed for `firmware-modern/`

[`firmware-modern/`](../firmware-modern/README.md) makes a **different, weaker
claim**: Linux 6.12 LTS from Analog Devices, with the transmitter-safety patches
rebased onto it, behaves the same, rather than producing the same bytes. Its
device tree is an overlay on ADI's own `.dtsi` instead of a decompiled flat
file, so byte-identity is not possible by construction; that target is meant to
be current, not a replica.

| | claim | evidence |
|---|---|---|
| `firmware/` | this **is** the factory firmware, rebuilt | byte-identical `.dtb` (before `0008`/`0011`), the `IKCONFIG` `.config` from the factory `uImage`, a file-by-file comparison with a real unit |
| `firmware-modern/` | this **behaves as** the factory firmware, on a current kernel | the IIO attribute list diffed against 5.15 (nine lines differ, each explained in [modern-kernel.md](modern-kernel.md)), the nine safety patches tested on hardware, and `./devkit selftest --loopback`: 32 passed, 0 failed |

The shared half (the bitstream, the block design, `BOOT.bin`, U-Boot) is the
same for both targets, so none of the hardware provenance above depends on which
kernel you build.

## Vendor resources

Published by the board's distributor. Useful primary reference, but none of it
includes editable HDL source.

- [**Hardware schematic**](vendor/7020_936x_SDR-schematic.pdf), kept in this
  repository because the vendor's own GitHub copy is a **different revision**
  that does not describe this board. [Which is which](vendor/README.md).
- [**PlutoSky R1 write-up**](https://blog.opensourcesdrlab.com/archives/PlutoSky-R1)
- [**Vendor file archive**](https://workupload.com/archive/kc2v7ryVZZ)
- [`OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR`](https://github.com/OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR):
  the prebuilt factory binaries.
