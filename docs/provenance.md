# Provenance: how close the rebuild is to the factory firmware

The board ships with no published, editable firmware source; this repository
reconstructs it from public sources. This page states what is claimed about
that reconstruction, the evidence, and how to check it yourself.

## Check it yourself

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
# run from: the board. The configuration the running kernel was built with
zcat /proc/config.gz
```

Compare that output between a factory board and your build. More in
[`firmware/README.md`](../firmware/README.md) and
[Verify your build is actually running](flashing.md#verify-your-build-is-actually-running).

## What is claimed

| | claim | evidence |
|---|---|---|
| `firmware/` | this **is** the factory firmware, rebuilt | byte-identical `.dtb` (before `0008`/`0011`), the `IKCONFIG` `.config` from the factory `uImage`, a file-by-file comparison with a real unit |
| `firmware-modern/` | this **behaves as** the factory firmware, on a current kernel | the IIO attribute list diffed against 5.15 (nine lines differ, each explained in [modern-kernel.md](modern-kernel.md)), the nine safety patches tested on hardware, and `./devkit selftest --loopback`: 32 passed, 0 failed |

`firmware/` compared file by file with a real factory unit's SD card:

| File | Result |
|---|---|
| `devicetree.dtb` | patch `0002` recompiles byte for byte to the factory file. Two later patches change it on purpose: `0008` (GPIO line names) and `0011` (probe-time transmit attenuation) |
| `uEnv.txt` | the same content; only the order U-Boot dumps its variables in differs |
| root filesystem | the same file list |
| kernel `.config` | identical to the one extracted from the factory `uImage` |
| `uImage`, U-Boot | within a few hundred bytes of the originals, not identical: upstream's history was squashed *after* this board's firmware was built, so some source cannot be recovered |

`firmware-modern/` claims the same behaviour, not the same bytes: its device
tree is an overlay on ADI's `.dtsi`, so byte-identity is impossible by
construction. The bitstream, block design, `BOOT.bin` and U-Boot are shared by
both targets. The [patch list](../firmware/patches/README.md) explains each
change, including two upstream bugs.

## Sources

- **Starting point:** the upstream fork
  [`Xiaozhang-code-cloud/Fish-Wan-plutosdr-fw-7020-SDR`](https://github.com/Xiaozhang-code-cloud/Fish-Wan-plutosdr-fw-7020-SDR).
- **The board's [schematic](vendor/7020_936x_SDR-schematic.pdf)**, against
  which the pin constraints are checked by hand; similarly named projects
  compile cleanly but target different boards. It is kept in this repository
  because the vendor's GitHub copy is a different revision
  ([which is which](vendor/README.md)).
- **The distributor's prebuilt binaries,**
  [`OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR`](https://github.com/OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR),
  byte-identical to a real unit's SD card, with no editable HDL or kernel
  source.
- **The factory kernel's own configuration,** extracted from the factory
  `uImage` (built with `CONFIG_IKCONFIG`, which embeds its `.config`).
- Also from the distributor: the
  [PlutoSky R1 write-up](https://blog.opensourcesdrlab.com/archives/PlutoSky-R1)
  and a [vendor file archive](https://workupload.com/archive/kc2v7ryVZZ).
