# How this repo came to exist

The board ships with no published, editable firmware source. This firmware was
reverse-engineered and rebuilt from scratch, starting from the public upstream
fork
[`Xiaozhang-code-cloud/Fish-Wan-plutosdr-fw-7020-SDR`](https://github.com/Xiaozhang-code-cloud/Fish-Wan-plutosdr-fw-7020-SDR),
cross-referenced against:

- **The board's real schematic**, used to check the HDL project's pin
  constraints by hand. Several other candidate projects compiled perfectly well
  and turned out to target *different*, similarly-named boards.
- **A byte-for-byte comparison** against
  [`OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR`](https://github.com/OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR),
  confirming it as the genuine source of the prebuilt binaries (though not of
  editable HDL/kernel source, which was never published).
- **An extracted `IKCONFIG` kernel `.config`** pulled out of the real
  firmware's compiled kernel image, proving this rebuild's configuration
  identical rather than merely close.

The result was then verified file by file against a real unit. The device tree
recompiles byte-for-byte identical to the factory one, with patch `0008` adding
`gpio-line-names` as the one intentional departure. `uEnv.txt` and
the rootfs file list are content-identical. Kernel and bootloader come out
within a few hundred bytes of the originals (the
upstream history was squashed *after* this board's firmware was built, so some
source has drifted — not recoverable from public sources). The
[firmware README](../firmware/README.md) has the exact patch list, including two
genuine upstream bugs found along the way.

## What this claim does and does not cover

Everything above is about [`firmware/`](../firmware/README.md), the factory
reconstruction. It is what lets this repo say *"a rebuild matches a shipped
board"* rather than *"a rebuild works"*, and it is why that target is kept even
though a newer kernel now exists beside it.

[`firmware-modern/`](../firmware-modern/README.md) makes a **different claim, and
a weaker one**: Linux 6.12 LTS from Analog Devices, with the same
transmitter-safety patches rebased onto it and the same RF behaviour *measured*
rather than the same bytes produced. Its device tree is a ~200-line overlay on
ADI's own `.dtsi` instead of a decompiled flat file, so byte-identity is given up
by construction — deliberately, because the point of that target is to be current
rather than to be a replica.

Two claims, both true, neither pretending to be the other:

| | claim | evidence |
|---|---|---|
| `firmware/` | this **is** the factory firmware, rebuilt | byte-identical `.dtb`, an `IKCONFIG` `.config` extracted from the factory `uImage`, a file-by-file diff against a real unit |
| `firmware-modern/` | this **behaves as** the factory firmware, on a current kernel | the IIO attribute contract diffed against 5.15 (nine lines differ, all explained), the nine safety patches re-measured on hardware, and `./devkit selftest --loopback`: 32 passed, 0 failed |

The shared half — the bitstream, the block design, `BOOT.bin`, U-Boot and the
rootfs — is identical in both, so nothing in the hardware provenance above is
affected by which kernel you build.

## Vendor resources

Published by the board's distributor — useful primary reference, but none of it
includes editable HDL sources, which is the gap this repo fills.

- [**Hardware schematic**](vendor/7020_936x_SDR-schematic.pdf) — kept here,
  because the vendor's own GitHub copy is a **different revision** that does not
  describe this board. [Which is which](vendor/README.md).
- [**PlutoSky R1 write-up**](https://blog.opensourcesdrlab.com/archives/PlutoSky-R1)
- [**Vendor file archive**](https://workupload.com/archive/kc2v7ryVZZ)
- [`OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR`](https://github.com/OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR)
  — confirmed by checksum as the genuine source of the prebuilt factory binaries.
