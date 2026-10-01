# Exact command sequences

Run `./devkit doctor` first: it checks everything a build needs in about a
second.

## Two targets, one entry point

`./devkit` takes `--target factory|modern` on `doctor`, `setup`, `build`,
`verify`, `flash`, `status` and `write-card`. **Factory is the default**, so
every command below without it means `firmware/`.

```bash
# run from: the repo root
./devkit setup --target modern        # ADI 6.12 + the boot side only: U-Boot,
                                      # embeddedsw, bootgen (~0.3 GB, ~20 s for
                                      # the boot side; the kernel clone is extra).
./devkit container build --target modern --xsa firmware/src/hdl/projects/pluto/system_top.xsa
./devkit verify --target modern       # BOOT.bin's partitions, read back out
./devkit flash --target modern --boot-only      # or --kernel-only, or --dtb-only
```

Rules for the modern target:

- **`--xsa` is REQUIRED for modern.** There is no Vivado path and no safe
  default: v1.6, v1.7 and a current from-source build all carry DIFFERENT
  bitstreams. Never substitute a release XSA silently, or the board runs
  another FPGA design. `firmware/src/hdl/projects/pluto/system_top.xsa` exists
  only after a factory (Vivado) build; without Vivado use
  `./firmware-modern/fetch-pinned-xsa.sh` (the factory release named in
  `firmware-modern/factory-xsa.pin`, sha256-checked) and SAY it is that
  release's design (v1.7: OLDER than main's).
- **A modern RELEASE ships BOOT.bin** built from exactly the pinned XSA;
  release.yml refuses any other. Changing its FPGA design = bump the pin in one
  commit. `gh workflow run release.yml -f tag=main -f target=modern -f dry_run=true`
  runs every gate and publishes nothing. It REFUSES unless
  `firmware-modern/output` is built from the pin AND the board runs that
  BOOT.bin. v2.2 is the latest modern release, and the board currently runs the
  v2.2 files (v1.7's FPGA design, per `firmware-modern/output/xsa-provenance.txt`).
  Flashing another design onto it is an operator decision: it is the board
  Hardware CI tests.
- `write-card --from DIR` writes a card from a downloaded modern release (every
  boot file checked against its SHA256SUMS; with no bootgen, that match is what
  vouches for BOOT.bin).
- **write-card takes BOOT.bin only from `BOOT_BIN=` or the modern output**, and
  refuses otherwise. Never feed it a flash backup: that is the design from
  BEFORE the last flash.
- `flash --target modern --all` / `--rootfs-only` are **refused**: the modern
  root is Debian on the card's p2, not a file. `build --target modern
  --rootfs-only` builds it (`debian/rootfs.tar`, no `--xsa`; `--all` = boot
  files + rootfs), on the HOST only: it is refused inside `./devkit container`.
  It registers armhf emulation itself via `tonistiigi/binfmt` when it can
  (rootful runtime only). `write-card --target modern` writes a whole card
  (`--dry-run`, or `--image NEW_FILE` to test without a card).
- **Rebuild `firmware-modern/debian/rootfs.tar` after any `overlay/` change.**
  write-card refuses a stale one, because a stale tarball can lack safety
  settings (such as the 60 s cyclic-transmit bound). Do not reach for
  `OVERLAY_OK=1` on a card that transmits.
- **The modern BOOT.bin is the factory BOOT.bin rebuilt**: given the same XSA,
  FSBL and bitstream partitions are byte-identical to the board's, and U-Boot
  differs only inside its build-date string. Check any BOOT.bin with
  `firmware/scripts/check_bootbin.py BOOT.bin --xsa FILE` (or `--ref OTHER`).
  Hashing the `.bit` never matches: bootgen stores it converted.

Rules for both targets:

- **Either ARM Linux compiler works on both targets.** Both `build_all.sh`
  scripts pick `arm-linux-gnueabi` first, else `arm-linux-gnueabihf`, and
  compile U-Boot with `CC="${CROSS}gcc -mfloat-abi=soft"`; without that, a
  hard-float compiler fails U-Boot's `-march=armv7-a` probe and blames armv5.
  On Ubuntu 22.04 GCC 11 both compilers give the same U-Boot instructions.
  **Factory: prefer gnueabi**, because only it reproduces the factory kernel
  byte for byte; a gnueabihf fallback prints a NOTE. Soft- and hard-float
  modern kernels both boot, and so does a hard-float U-Boot (FSBL and
  bitstream identical to the soft-float build; uboot-contract matches the
  baseline, selftest and gpio-check pass).
- **Arch has no ARM Linux cross-compiler in its official repositories.** Use
  Arm's prebuilt GNU Toolchain (minutes, no root) linked under the
  `arm-linux-gnueabihf-*` names in `~/.local/bin`, or build the AUR packages
  one stage at a time (`yay -S arm-linux-gnueabihf-gcc` in one go stops after
  binutils and the kernel headers). See docs/building.md, "An ARM
  cross-compiler on Arch". The development host uses Arm GNU Toolchain
  15.2.rel1 that way; with it (and Arch's arm-none-eabi 16.2 for the FSBL)
  `./devkit build --target modern --all` runs end to end on the host. The
  kernel also needs `bc`; preflight checks it.
- **The container has `arm-linux-gnueabi` 11.4.** On a host with no ARM Linux
  cross-compiler, prefix `container`: a modern `build` there stops in
  preflight and names that command, which is not a failure to debug.
- **bootgen must RUN where it is used**, not just exist: a host-built one (new
  glibc) does not run in the 22.04 container. `devkit_ensure_bootgen` in
  `firmware/scripts/fetch_common.sh` rebuilds it; do not hand-copy binaries.
- **Pins live only in `firmware/scripts/fetch_common.sh`**, sourced by both
  targets' setup. Change a pin there, never in a setup script.
- **Unplugging the USB data cable:** on bus power it power-cycles the board;
  powered from a charger, `usb0` keeps 192.168.2.1 across a replug. If
  192.168.2.1 is silent after a replug, check the PC's end first. The serial
  console `/dev/ttyACM0` needs no IP and works right after a replug.
- **Do not edit a script a background build is executing.** bash reads it
  incrementally from a byte offset, so an edit above the current line makes the
  run resume at the wrong place. Stop the run, edit, re-run.

## Build (factory)

```bash
# run from: the repo root
source tools/env-vivado.sh          # before any vivado command (not needed for --xsa)
cd firmware
./scripts/setup.sh                  # once: clones upstream into src/, applies patches/*.patch
# (the modern target: ./devkit setup --target modern, from the repo root - see above)
./scripts/build_all.sh              # full: ~70 min
./scripts/build_all.sh --hdl-only   # reuses kernel/u-boot/rootfs: ~20 min
```

`setup.sh` applies `patches/*.patch` in sorted order and skips
`patches/optional/`. To use a worked example:

```bash
# run from: firmware/
(cd src && git apply ../patches/optional/0003-wbfm-channelizer.patch)
```

**Then delete the Vivado project**, or the change is silently ignored
(`build_hdl.tcl` reuses an existing `pluto.xpr`):

```bash
# run from: firmware/
rm -rf src/hdl/projects/pluto/pluto.{xpr,cache,gen,hw,ip_user_files,runs,sim,srcs,sdk}
```

## Kernel only

Much faster than `build_all.sh` when only the driver changed. **Which tree
depends on the target**: `firmware-modern/` (Linux 6.12, the default for kernel
work) or `firmware/` (5.15, the factory reconstruction).

On `firmware-modern/`, `./devkit build --target modern --boot-only` skips the
kernel and still requires `--xsa`. For a kernel-only iteration by hand there is
no `PATH` juggling, because the tree is just a kernel and the defconfig names
everything:

```bash
# run from: firmware-modern/src/linux         (created by ../../setup.sh)
CROSS=../../../firmware/src/buildroot/output/host/bin/arm-linux-gnueabihf-
make ARCH=arm CROSS_COMPILE=$CROSS fishball_defconfig          # once
make ARCH=arm CROSS_COMPILE=$CROSS uImage LOADADDR=0x8000 -j$(nproc)
make ARCH=arm CROSS_COMPILE=$CROSS DTC_FLAGS=-@ xilinx/zynq-pluto-sdr-fishball.dtb
cp arch/arm/boot/uImage ../../output/
cp arch/arm/boot/dts/xilinx/zynq-pluto-sdr-fishball.dtb ../../output/devicetree.dtb
```

Either ARM Linux GCC works (`CROSS=arm-linux-gnueabi-` or
`CROSS=arm-linux-gnueabihf-` from your PATH); the Linaro 7.3 above is just the
one a factory build of `firmware/` leaves behind. A kernel takes about two
minutes, a device tree seconds. **Never build `zynq_pluto_defconfig` there**:
it describes an ADALM-Pluto and produces a board with no Ethernet, no SD card
and no GPIO sysfs, which boots and looks fine until you notice.

Then point the flasher at that output directory:

```bash
# run from: the repo root
./devkit flash --target modern --kernel-only
```

On `firmware/` the tree is a monorepo, so the host tools need to be on `PATH`:

```bash
# run from: the repo root
cd firmware
SRC=$PWD/src
PATH="$SRC/buildroot/output/host/bin:$SRC/buildroot/output/host/sbin:$PATH" \
  make -C "$SRC/linux" -j"$(nproc)" ARCH=arm \
  CROSS_COMPILE=arm-linux-gnueabihf- uImage UIMAGE_LOADADDR=0x8000
cp src/linux/arch/arm/boot/uImage output/uImage
```

Device tree only: same, with target `zynq-pluto-sdr-fishball.dtb` and
`DTC_FLAGS=-@`, then copy to `output/devicetree.dtb`.

**Check a device tree by building it and auditing the `.dtb`**, not by reading
the `.dts`: on `firmware-modern/` most of the tree comes from ADI's `.dtsi`.

```bash
# run from: the repo root
python3 firmware-modern/verify_dtb.py \
  firmware-modern/src/linux/arch/arm/boot/dts/xilinx/zynq-pluto-sdr-fishball.dtb
```

## Flashing

Use the script. It backs up, verifies checksums before the swap, unmounts
cleanly, reboots, and confirms the card afterwards. Never copy files to the
card by hand: a missing `mkdir -p` after a reboot makes `scp` write nothing,
and the board reboots into the old image.

```bash
# run from: the repo root
./devkit flash               # BOOT.bin + uImage - the usual case
./devkit flash --boot-only   # an HDL change
./devkit flash --kernel-only # a driver change
./devkit flash --all         # everything, e.g. a release
BOARD=192.168.1.50 BOARD_PASS=analog ./devkit flash   # a board elsewhere
```

It reports success only once `/proc/uptime` has reset (a board shutting down
still answers ssh for a few seconds) and the card's md5s match `output/`. The
previous files stay on the card as `*.prev` and in
`firmware/.flash-backups/<stamp>/`. Never DFU for `BOOT.bin` (it has no target
for it), and never pull power mid-write. Afterwards, `./devkit verify --board`.

## After flashing

```bash
# run from: firmware/
python3 ../tools/selftest/sdr_selftest.py --ssh                        # never transmits
python3 ../tools/selftest/sdr_selftest.py --ssh --loopback --pad 30    # + RF, needs a cable
```

Denser frequency data, or a crossed loop that separates the transmit chain from
the receive chain (see `measuring.md`):

```bash
# flags to add to either sdr_selftest.py run above
--sweep-points 60 --sweep-start 70e6 --sweep-stop 6e9
--tx-channel 0 --rx-channel 1
```

## Recovering

Keep a copy of a known-good `output/` before experimenting. The distributor's
prebuilt factory firmware is at `OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR`,
confirmed by checksum against a real unit; copying those files onto the SD card
returns the board to its shipped state.

## Building in a container

**This is the recommended build route.** `./devkit container build --hdl-only`
runs the build inside a pinned Ubuntu 22.04 image with `$XILINX_DIR` (default
`/tools/Xilinx`) bind-mounted read-only. Vivado installed by
`./devkit container install` into a fresh directory produces a
**byte-for-byte identical `BOOT.bin`**. `./devkit doctor` points at it when the
host OS is too new.

All five SD-card files are reproducible. `uramdisk.image.gz` needs `mkimage`
pinned with `SOURCE_DATE_EPOCH`: it re-wraps the rootfs every build, including
`--hdl-only`, and would otherwise stamp the current time into u-boot's header.

Two failures whose error does not name the cause:

**Vivado dies mid-synthesis** with `tcmalloc: large alloc 115875935977472
bytes` or `realloc(): invalid pointer`. Its licence manager `dlopen`s
`libudev.so.1` and enumerates every device to fingerprint the host, by which
point Vivado's tcmalloc has replaced malloc process-wide while libudev still
frees through glibc. `tools/container/udev-stub.c` answers with an empty list
and never allocates. Do **not** reach for `MALLOC_CHECK_`: it hides real heap
corruption in the tool that builds your bitstream. Mounting `/run/udev`,
`config_webtalk -user off` and using Ubuntu 20.04 do not fix it.

**A bare `Channel closed` from `xsct`** cannot happen any more: there is no
xsct path, and the FSBL is built from embeddedsw. The image carries only GTK2,
which is Vivado's.

Also: mount the repo at **its own absolute path**, because `pluto.xpr` stores
absolute paths. `tools/env-vivado.sh` engages the `legacy-libs` shim only where
the distro lacks `libtinfo.so.5`, since those copies link `GLIBC_2.33` and
cannot load on anything older than jammy.

Full write-up: [`docs/building-in-a-container.md`](../../../../docs/building-in-a-container.md)
