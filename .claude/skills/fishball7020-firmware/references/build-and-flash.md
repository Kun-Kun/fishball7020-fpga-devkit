# Building, flashing and the patch set

Run `./devkit doctor` first: it checks the compilers, host packages, disk and
the sources (`./devkit doctor --target factory` also Vivado, the bare-metal
cross-compiler, `gmp.h`, ~25 GB of disk for a full build, the patch stamp and
the board) in about a second; each check is a failure that otherwise costs an hour
mid-build. `./devkit --help` lists every command; each subcommand's own
`--help` has the full flag list.

## Typical work

```bash
# run from: the repo root - an HDL change (factory target)
./devkit sim                                 # golden-model check, ~1 s
rm -rf firmware/src/hdl/projects/pluto/pluto.{xpr,cache,gen,hw,ip_user_files,runs,sim,srcs,sdk}
./devkit build --target factory --hdl-only   # ~20 min; 70 from cold
./devkit verify --target factory             # five files, compressed bitstream, timing
./devkit flash --target factory --boot-only
./devkit verify --target factory --board     # read the verdict; it never changes $?
./devkit selftest --ssh
```

**A kernel change**: edit the tree, rebuild `uImage` alone (below; minutes,
not a full `build`), `./devkit flash [--target factory] --kernel-only`. Then fold
the change into a numbered patch so a fresh clone gets it, and add a CI
assertion: `firmware-modern/patches/` with `verify-modern.yml`, or
`firmware/patches/` with `verify-patches.yml`.

**Before a release**: run a clean-clone end-to-end build. It exercises the
build's own self-repair path, whose defects stop only the next person building
from a fresh clone.

## Two targets, one entry point

`./devkit` takes `--target factory|modern` on `doctor`, `setup`, `build`,
`verify`, `flash`, `status` and `write-card`. **Modern is the default**, so
every command without it means `firmware-modern/`; `--target factory` means
`firmware/`, and `DEVKIT_TARGET=factory` in the environment restores the old
factory default.

```bash
# run from: the repo root
./devkit setup                        # ADI 6.12 + the boot side: U-Boot,
                                      # embeddedsw, bootgen (~0.6 GB fetched)
./devkit build --xsa FILE             # boot files + kernel (--boot-only: skip the kernel)
./devkit build --rootfs-only          # Debian rootfs.tar, no --xsa, HOST only
./devkit verify                       # BOOT.bin's partitions, read back out
./devkit flash --boot-only            # or --kernel-only, or --dtb-only
sudo ./devkit write-card /dev/sdX     # a whole card: boot on p1, Debian on p2
```

Rules for the modern target:

- **`--xsa` is REQUIRED for modern.** There is no Vivado path and no safe
  default: v1.6, v1.7 and a current from-source build all carry DIFFERENT
  bitstreams. Never substitute a release XSA silently, or the board runs
  another FPGA design. `firmware/src/hdl/projects/pluto/system_top.xsa` exists
  only after a factory (Vivado) build; without Vivado use
  `./firmware-modern/fetch-pinned-xsa.sh` (the factory release named in
  `firmware-modern/factory-xsa.pin`, sha256-checked) and SAY it is that
  release's design. `firmware-modern/output/xsa-provenance.txt` records which
  XSA the current output came from.
- **A modern RELEASE ships BOOT.bin** built from exactly the pinned XSA;
  `release.yml` refuses any other. Changing its FPGA design = bump the pin in
  one commit. `gh workflow run release.yml -f tag=main -f target=modern -f dry_run=true`
  runs every gate and publishes nothing. It REFUSES unless
  `firmware-modern/output` is built from the pin AND the board runs that
  BOOT.bin. Which release is latest and what the board runs change often:
  ask `gh release list` and `./devkit status`, do not assume. Flashing another
  design onto the bench board is an operator decision: it is the board
  Hardware CI tests.
- `write-card --from DIR` writes a card from a downloaded modern release (every
  boot file checked against its SHA256SUMS; with no bootgen, that match is what
  vouches for BOOT.bin).
- **A Windows user with no clone: `tools/write-card.cmd`**, shipped as a
  release asset. Double-clicked in the folder of a modern release's files it
  checks SHA256SUMS, backs up the card, and writes MBR + FAT32 `FISHBOOT` +
  `fishroot` itself; the root is **ext3** built by embedded C# (Windows cannot
  make ext4 and WSL cannot attach a USB reader), mounted by the ext4 driver.
  Must stay C# 5 and use only mscorlib/System.dll (Windows PowerShell 5.1's
  `Add-Type`). `-ImageFile` writes an image; `tools/check_card_image.py`
  checks one against a release. CI runs it on Windows into a VHD.
- **write-card takes BOOT.bin only from `BOOT_BIN=` or the modern output**, and
  refuses otherwise. Never feed it a flash backup: that is the design from
  BEFORE the last flash.
- On modern, `flash --all` / `--rootfs-only` are **refused**: the modern
  root is Debian on the card's p2, not a file. `build --rootfs-only` builds it (`firmware-modern/debian/rootfs.tar`; `--all` = boot
  files + rootfs), on the HOST only: it is refused inside `./devkit container`.
  It registers armhf emulation itself via `tonistiigi/binfmt` when it can
  (rootful runtime only). `write-card` has `--dry-run`, and `--image NEW_FILE`
  to test without a card.
- **Rebuild `rootfs.tar` after any `firmware-modern/debian/overlay/` change.**
  write-card refuses a tarball older than the overlay, because a stale one can
  lack safety settings (such as the 60 s cyclic-transmit bound). Do not reach
  for `OVERLAY_OK=1` on a card that transmits.
- **The modern BOOT.bin is the factory BOOT.bin rebuilt**: given the same XSA,
  FSBL and bitstream partitions are byte-identical to the board's, and U-Boot
  differs only inside its build-date string. Check any BOOT.bin with
  `firmware/scripts/check_bootbin.py BOOT.bin --xsa FILE` (or `--ref OTHER`).
  Hashing the `.bit` never matches: bootgen stores it converted.
- `firmware-modern/write_card.sh` (underscore) is a separate escape hatch: it
  copies only `uImage` + `devicetree.dtb` onto a desktop-mounted card, for a
  kernel that lost networking or MMC (`--restore` puts the 5.15 files back).

Rules for both targets:

- **Either ARM Linux compiler works on both targets.** Both `build_all.sh`
  scripts pick `arm-linux-gnueabi` first, else `arm-linux-gnueabihf`, and
  compile U-Boot with `CC="${CROSS}gcc -mfloat-abi=soft"`; without that, a
  hard-float compiler fails U-Boot's `-march=armv7-a` probe and blames armv5.
  **Factory: prefer gnueabi**, because only it reproduces the factory kernel
  byte for byte; a gnueabihf fallback prints a NOTE. Soft- and hard-float
  modern kernels both boot, and so does a hard-float U-Boot.
- **Arch has no ARM Linux cross-compiler in its official repositories.** Use
  Arm's prebuilt GNU Toolchain (minutes, no root) linked under the
  `arm-linux-gnueabihf-*` names in `~/.local/bin`; the AUR packages stop after
  binutils and the kernel headers when installed in one go. See
  [docs/building.md, "An ARM cross-compiler on Arch"](../../../../docs/building.md#an-arm-cross-compiler-on-arch).
  The kernel also needs `bc`; preflight checks it.
- **The container has `arm-linux-gnueabi` 11.4.** On a host with no ARM Linux
  cross-compiler, prefix `container`: a modern `build` there stops in
  preflight and names that command, which is not a failure to debug.
- **bootgen must RUN where it is used**, not just exist: a host-built one (new
  glibc) does not run in the 22.04 container. `devkit_ensure_bootgen` in
  `firmware/scripts/fetch_common.sh` rebuilds it; do not hand-copy binaries.
- **Pins live only in `firmware/scripts/fetch_common.sh`**, sourced by both
  targets' setup. Change a pin there, never in a setup script.
- **Do not edit a script a background build is executing.** bash reads it
  incrementally from a byte offset, so an edit above the current line makes the
  run resume at the wrong place. Stop the run, edit, re-run.
- **Unplugging the USB data cable:** on bus power it power-cycles the board;
  powered from a charger, `usb0` keeps 192.168.2.1 across a replug; if it is
  silent after a replug, check the PC's end first. The serial
  console `/dev/ttyACM0` (Debian) needs no IP and works right after a replug.

## Build (factory)

```bash
# run from: the repo root
./devkit setup --target factory     # once, and after every new patch: clones upstream, applies patches
./devkit build --target factory     # full: 45-90 min
./devkit build --target factory --hdl-only   # reuses kernel/u-boot/rootfs: ~20 min
./devkit build --target factory --xsa FILE   # no Vivado at all: an already-built hardware platform
```

`--xsa` skips stage `[1/7]` entirely, so a kernel/driver/rootfs change needs no
Vivado; `verify_output.sh` then describes the design from the platform's own
`system.hwh` and reports timing as unavailable rather than failing. See
[`docs/building-without-vivado.md`](../../../../docs/building-without-vivado.md).
Vivado itself needs `source tools/env-vivado.sh` when run by hand.

`setup.sh` applies `patches/*.patch` in sorted order and skips
`patches/optional/`. To use a worked example:

```bash
# run from: firmware/
(cd src && git apply ../patches/optional/0003-wbfm-channelizer.patch)
```

### The Vivado-project trap

`build_hdl.tcl` reuses an existing `pluto.xpr` rather than re-running
`system_bd.tcl`, so a changed block design or `.coe` is ignored and the old
bitstream is rebuilt. `build_all.sh` now refuses when `system_bd.tcl`,
`system_top.v`, `system_constr.xdc`, the project's `*.v` or `coefile_*.coe` is
newer than `pluto.xpr` (`FORCE_STALE_PROJECT=1` overrides), but nothing else is
checked: an edit to ADI library IP, a file restored with an old mtime, or a
patch applied elsewhere is still reused silently. Delete the project before
any HDL or coefficient change:

```bash
# run from: firmware/
rm -rf src/hdl/projects/pluto/pluto.{xpr,cache,gen,hw,ip_user_files,runs,sim,srcs,sdk}
```

Under `--xsa` there is no project, so the trap cannot apply. `system_bd.tcl`
holds both wirings of patch `0021`; read `system.bd` (or the XSA's
`system.hwh`) for what was actually built.

### Simulate, then verify

`./devkit sim` (`firmware/sim/run_sim.sh`) checks the custom HDL against a
golden model in about a second; synthesis cannot tell you the logic computes
the wrong thing. `--mutate` proves the testbench can still fail.

`./devkit verify --target factory` (`firmware/scripts/verify_output.sh`) checks the five files,
that the bitstream is compressed (an uncompressed one overflows the FSBL's OCM
and BOOT.bin fails to boot with no message), and that timing is met. It prints
the DSP count and which coefficients are in use, so you can see your change
landed. It checks exactly `pluto.runs/impl_1/system_top.bit`, the file
`build_all.sh` packages.

`./devkit verify --target factory --board` md5-compares the card against `output/` and is the
only thing that proves the board runs what you built. A STALE verdict means
the board is behind, not that the build is bad. **`--board` never changes the
exit status**; read the verdict. `--require-board` is the strict form for a
release gate: non-zero unless the card was read and every file matched.

`setup.sh` is idempotent (it stamps `src/.devkit-patches-applied` with a digest
of the patch set), and `build_all.sh` refuses an unpatched tree.

## Kernel only

**Which tree depends on the target**: `firmware-modern/` (Linux 6.12, the
default for kernel work) or `firmware/` (5.15, the factory reconstruction).

On `firmware-modern/` the tree is just a kernel and the defconfig names
everything:

```bash
# run from: firmware-modern/src/linux         (created by ./devkit setup)
CROSS=arm-linux-gnueabihf-                   # or arm-linux-gnueabi-; any ARM Linux GCC on PATH
make ARCH=arm CROSS_COMPILE=$CROSS fishball_defconfig          # once
make ARCH=arm CROSS_COMPILE=$CROSS uImage LOADADDR=0x8000 -j$(nproc)   # ~2 min
make ARCH=arm CROSS_COMPILE=$CROSS DTC_FLAGS=-@ xilinx/zynq-pluto-sdr-fishball.dtb
cp arch/arm/boot/uImage ../../output/
cp arch/arm/boot/dts/xilinx/zynq-pluto-sdr-fishball.dtb ../../output/devicetree.dtb
```

A factory build of `firmware/` also leaves a Linaro 7.3 gnueabihf compiler at
`firmware/src/buildroot/output/host/bin/arm-linux-gnueabihf-`. **Never build
`zynq_pluto_defconfig` there**: it describes an ADALM-Pluto and produces a
board with no Ethernet, no SD card and no GPIO sysfs, which boots and looks
fine until you notice. Then `./devkit flash --kernel-only`
(or `--dtb-only`).

On `firmware/` the tree is a monorepo, so the host tools need to be on `PATH`:

```bash
# run from: firmware/
SRC=$PWD/src
PATH="$SRC/buildroot/output/host/bin:$SRC/buildroot/output/host/sbin:$PATH" \
  make -C "$SRC/linux" -j"$(nproc)" ARCH=arm \
  CROSS_COMPILE=arm-linux-gnueabihf- uImage UIMAGE_LOADADDR=0x8000
cp src/linux/arch/arm/boot/uImage output/uImage
```

Device tree only: same, with target `zynq-pluto-sdr-fishball.dtb` and
`DTC_FLAGS=-@`, then copy to `output/devicetree.dtb`.

### Device trees

**Check a device tree by building it and auditing the `.dtb`**, not by reading
the `.dts`. On `firmware-modern/` the `.dts` is an overlay on ADI's
`zynq-pluto-sdr.dtsi`, so most of the `.dtb` is not in the file you edited.
Two failures invisible in the `.dts` that still boot: a `memory@0` node that
becomes a *sibling* of the dtsi's `memory` (the tree carries both 512 MB and
1 GB, and `dtc` says only "duplicate unit-address" against an unrelated node),
and ADI's `&sdhci0 { status = "disabled" }`, which means a card-reader trip
because `tools/flash.sh` works by mounting `/dev/mmcblk0p1` on the running
board. `verify_dtb.py` runs 16 checks, including that the transmit-attenuation
default is still 89750 mdB and that nothing the factory tree enables has gone
missing; CI runs it too.

```bash
# run from: the repo root
python3 firmware-modern/verify_dtb.py \
  firmware-modern/src/linux/arch/arm/boot/dts/xilinx/zynq-pluto-sdr-fishball.dtb
```

**Do not change the device tree without a strong reason.** On `firmware/` it
recompiles byte-for-byte identical to the factory board's, which is a
provenance claim; `0008` and `0011` are the exceptions, each its own patch so
dropping it restores the factory `.dtb`. On `firmware-modern/` there is no
byte-identity to protect, and the reason inverts: the tree is the one place a
setting cannot be changed without a reflash, so a trigger or a default belongs
in the driver or in the rootfs's own init (`fishball-rf-quiesce.service`,
**not** `S21misc`, which is Buildroot's).

## The patches

Full catalogue: [`firmware/patches/README.md`](../../../../firmware/patches/README.md)
and [`firmware-modern/patches/README.md`](../../../../firmware-modern/patches/README.md).
`firmware/patches/` has 18 (plus `optional/0003`); `firmware-modern/patches/`
has 9, drivers only (0004, 0005, 0007, 0012, 0015-0019).

- `0001` fixes and a persistent serial; `0002` the device tree.
- `0004` mutes TX when no DMA stream; `0005` makes the unmute restore a cached
  gain without overwriting one set before the stream (see `rf-safety.md`).
- `0006` routes each TX sample's low nibble (the bits the 12-bit DAC discards)
  to JP5 pins 7/9/11/13; `0007` adds the `tx_sample_gpio_en` attribute that
  enables it. Both edit `cf_axi_dds.c`, which 0004/0005 also touch.
- `0008` names those GPIO lines in the device tree (on `firmware-modern/` the
  names are part of the tree). `0009` gives the bit-map flag's clock-crossing
  constraint the `-from` it lacked: `set_max_delay -datapath_only` needs both
  ends, and without one Vivado drops the line silently.
- `0011` (device tree) probes the transmitter at maximum attenuation rather
  than 10 dB, which also makes a debugfs `initialize` land on silence.
- `0012` makes the USER LED follow the transmitter.
- `0013` pins eth0 to the MAC U-Boot already uses and sends a hostname in the
  DHCP request (without it the MAC is random every boot). `0014` makes the
  default hostname `fishball`, so the board answers to `fishball.local`.
- `0015` mutes when the DAC stops being fed, because `postdisable` is an event
  and events get missed. It corrects a claim `0004` made.
- `0016` adds the `tx_disable` latch that debugfs cannot clear. `0017` counts TX
  DMA underflows; `0018` refuses to get louder above a die temperature.
- `0019`, **`firmware-modern/` only**: never restore a cached attenuation of
  zero. The same bug is still on `firmware/` (see `rf-safety.md`).
- `0020` is a build fix with no radio behaviour: the host tools use U-Boot's own
  libfdt headers, which otherwise break stage [3/7] on any host that has
  `libfdt-dev` (or, on Arch, `dtc`).
- `0021` sends **both** receive channels through the ÷8 decimator. Upstream
  filters channel 0 and wires channel 1 straight to `cpack` with no
  anti-alias filter: about 70 dB of aliasing on RX2 the moment decimation
  engages. Applied by default; `STOCK_RX_FILTER=1` builds upstream's wiring.
  It costs 22 DSP48s and ~625 LUTs.
- `optional/0003` is the FM channelizer (it sets `rx_filt_chan 2` for its own
  worked example).

**To fix an applied patch, add a new one on top. Never edit it**: `setup.sh`
cannot re-apply a patch over its earlier version, so an edit breaks every
existing tree. Patches stack (0004, 0005 and 0007 all edit `cf_axi_dds.c`), so
generate a new patch to a stacked file against a reconstructed pre-change
copy, never a plain `git diff`. Why the "already applied?" checks are
stamp-based: `debugging.md`.

## Flashing

**Never DFU.** DFU has no `BOOT.bin` target, so it can never deliver an HDL
change, and on this board it has bricked units. Use the script: it mounts
`/dev/mmcblk0p1` on the running board, backs the card up to
`firmware/.flash-backups/<stamp>/` (gitignored), md5-verifies each copy BEFORE
swapping it in, keeps the old files on the card as `*.prev`, unmounts cleanly,
reboots, and reports success only once `/proc/uptime` has reset (a board
shutting down still answers ssh for a few seconds) and the card's md5s match.

```bash
# run from: the repo root
./devkit flash               # BOOT.bin + uImage - the usual case
./devkit flash --target factory --boot-only   # an HDL change
./devkit flash --kernel-only # a driver change; recoverable over the network
./devkit flash --target factory --dtb-only    # a device-tree patch (0002/0008/0011)
./devkit flash --target factory --all         # all five files, e.g. a release
BOARD=192.168.1.50 BOARD_PASS=analog ./devkit flash   # a board elsewhere
```

Never copy files to the card by hand: a missing `mkdir -p` after a reboot
makes `scp` write nothing, and the board reboots into the old image. Never pull
power mid-write. A bad `BOOT.bin` removes the network route entirely: recovery
is a card reader (`tools/make-sd-card.sh` for a factory card,
`./devkit write-card` for a Debian one). Afterwards,
`./devkit verify --board`.

## After flashing

```bash
# run from: the repo root
./devkit selftest --ssh                          # never transmits
./devkit tx-guard affirm 0                       # after LOOKING at TX1A
./devkit selftest --ssh --loopback --pad 20      # + RF; --pad = the pad actually fitted
```

Denser frequency data, or a crossed loop that separates the transmit chain from
the receive chain (see `measuring.md`):

```bash
# flags to add to either selftest run above
--sweep-points 60 --sweep-start 70e6 --sweep-stop 6e9
--tx-channel 0 --rx-channel 1
```

## Recovering

Keep a copy of a known-good `output/` before experimenting. The distributor's
prebuilt factory firmware is at `OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR`,
confirmed by checksum against a real unit; copying those files onto the SD card
returns the board to its shipped state.

## Building in a container

**This is the recommended build route.** `./devkit container build --target factory --hdl-only`
runs the build inside a pinned Ubuntu 22.04 image with `$XILINX_DIR` (default
`/tools/Xilinx`) bind-mounted read-only. Vivado installed by
`./devkit container install` into a fresh directory produces a
**byte-for-byte identical `BOOT.bin`**. `./devkit doctor --target factory` points at it when the
host OS is too new.

All five SD-card files are reproducible. `uramdisk.image.gz` needs `mkimage`
pinned with `SOURCE_DATE_EPOCH`: it re-wraps the rootfs every build, including
`--hdl-only`, and would otherwise stamp the current time into u-boot's header.

**Vivado dies mid-synthesis** with `tcmalloc: large alloc 115875935977472
bytes` or `realloc(): invalid pointer`. Its licence manager `dlopen`s
`libudev.so.1` and enumerates every device to fingerprint the host, by which
point Vivado's tcmalloc has replaced malloc process-wide while libudev still
frees through glibc. `tools/container/udev-stub.c` answers with an empty list
and never allocates. Do **not** reach for `MALLOC_CHECK_`: it hides real heap
corruption in the tool that builds your bitstream. Mounting `/run/udev`,
`config_webtalk -user off` and using Ubuntu 20.04 do not fix it.

Also: mount the repo at **its own absolute path**, because `pluto.xpr` stores
absolute paths. `tools/env-vivado.sh` engages the `legacy-libs` shim only where
the distro lacks `libtinfo.so.5`, since those copies link `GLIBC_2.33` and
cannot load on anything older than jammy. The container has no `ping` and no
mDNS; `tools/container/run.sh` resolves a `.local` name on the host and
forwards it as `$BOARD` plus `--add-host`.

Full write-up: [`docs/building-in-a-container.md`](../../../../docs/building-in-a-container.md)
