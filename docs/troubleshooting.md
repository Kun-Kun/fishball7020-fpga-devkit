# Troubleshooting

Problems people have actually hit, and what fixed them. If the radio itself
misbehaves rather than the build, run the [self-test](../tools/selftest/README.md) first.

- **The board goes unresponsive after a while — ssh, libiio and even ping all
  stop, but it is still enumerated on USB. Use mains power.** The board has two
  USB connectors; on laptop bus power alone a PA-equipped board browns out under
  sustained use. Measured 2026-09-30: healthy for hours, degrading, then wedging
  within a minute of any real work, with `ad9361 spi0.0: Calibration TIMEOUT`
  repeating, then `Failed to find suitable dividers: ADC clock below limit`, then
  a plain `echo ... > .../in_voltage_sampling_frequency` blocking forever.
  Nothing responds afterwards — not ssh, not libiio over the network *or* USB,
  not the `ttyACM0` gadget console — and only a physical replug clears it.

  What identifies it as supply rather than a board fault is the kernel log: the
  board dropped, and **one second later the entire hub tree on a different root
  port** went with it — a 500 mA HackRF, two hubs and three peripherals — and all
  re-enumerated together. No board-specific fault can reach across two root
  ports. `device descriptor read/64, error -71` and `error -110` are the same
  brownout signature.

  Put the second USB cable on a **mains charger**, not another port on the same
  laptop, where it shares the budget. The discriminator is `./devkit selftest`:
  on bus power it wedged the board twice, at the 4 MHz `set_rate` in
  `test_receiver`; on mains it passes `24 passed, 0 failed, HEALTHY`, including
  across a reboot, with zero Calibration TIMEOUTs.

- **ssh works but nothing can open the radio (`iio_info -u ip:192.168.2.1` fails,
  SDR++ finds no device) — Debian root.** iiod is held back on purpose when the
  boot-time transmitter mute could not be proven: it `Requires=`
  `fishball-rf-quiesce`, so the board has no SDR service rather than one with a
  possibly unmuted transmitter. The network and console come up anyway. Ask why:
  ```bash
  # run on the board
  journalctl -b -u fishball-rf-quiesce -u iiod
  ```
  Fix what it names (usually `ad9361-phy` missing, i.e. the FPGA or device tree),
  then reboot: the USB libiio function the fallback left out is only put back at
  boot.

- **SDRangel lists the board as `PlutoSDR0 TBD` and won't open it.** SDRangel
  identifies Plutos by serial number, and firmware built before patch 0001
  reported an empty one — this board's W25Q128 flash never emits the
  `SPI-NOR-UniqueID` line the boot script looks for. Rebuild with the current
  `patches/` and reflash; the board mints a persistent serial on first boot. If
  SDRangel is a snap, also `sudo snap connect sdrangel:raw-usb`.
- **U-Boot fails with `arm-linux-gnueabihf-gcc: error: unrecognized -march
  target: armv5`.** You installed `gcc-arm-linux-gnueabi**hf**`; this build
  wants `gcc-arm-linux-gnueabi` (soft float). The error is three steps from its
  cause: Ubuntu's hard-float compiler defaults to `-mfloat-abi=hard`, U-Boot
  probes `-march=armv7-a` which specifies no FPU, hard-float plus no-FPU is an
  error, so `cc-option` falls through to `-march=armv7` and then `-march=armv5`,
  which GCC 11 genuinely does not accept. Nothing here is ARMv5.
  `sudo apt install gcc-arm-linux-gnueabi` fixes it; `./devkit doctor` catches
  it up front.
- **`vivado` fails to start, or complains about missing shared
  libraries** — you sourced Vivado's `settings64.sh` instead of
  `tools/env-vivado.sh`.
- **Vivado dies mid-synthesis with `tcmalloc: large alloc 115875935977472
  bytes` or `realloc(): invalid pointer`, in a container.** That 115 TB
  request is an integer underflow. Vivado's licence manager `dlopen`s
  `libudev.so.1` and enumerates every device to fingerprint the host, by which
  point its bundled tcmalloc has replaced `malloc` process-wide while libudev
  still frees through glibc. `./devkit container` loads a stub libudev that
  answers with an empty list — see
  [Building in a container](building-in-a-container.md). Do **not** silence it
  with `MALLOC_CHECK_`: that hides real heap corruption in the tool that
  builds your bitstream.
- **The FSBL stage fails with a bare `Channel closed` from `xsct`.** Not
  reachable any more — the xsct path was removed on 2026-09-28 and the FSBL is
  built from embeddedsw. If you are seeing this, you are on an older checkout;
  update, or install GTK3 and the SWT libraries alongside Vivado's GTK2.
- **The kernel build fails with `GLIBC_2.xx not found` in a `gcc-plugins`
  step** — you sourced `env-vivado.sh` in the same shell you then built the
  kernel in; it injects Xilinx toolchain directories into `PATH` that conflict.
  `build_all.sh` isolates this correctly; by hand, use a fresh shell.
- **U-Boot stage [3/7] fails at `tools/aisimage.o` with `conflicting types for
  'fdt64_t'`** and a wall of redefinitions naming `/usr/include/libfdt.h`. Your
  host has libfdt's headers installed — `libfdt-dev` on Debian/Ubuntu, and on
  Arch they come with `dtc`, which this repo requires. u-boot's `tools/Makefile`
  searches its own `include/` *after* the system directories, so the system
  header wins and disagrees with u-boot about `fdt32_t`/`fdt64_t`. Fixed by
  patch `0020`; if you are seeing this, your tree predates it — `./devkit setup`
  applies it. Do **not** uninstall the package: on Arch that would take `dtc`
  with it.

- **U-Boot/kernel builds fail with `unrecognized -march target: armv5`** —
  Buildroot's cross-compiler (stage 1b) isn't built yet. Re-run `build_all.sh`
  rather than invoking `make` directly.
- **Buildroot fails with `has wrong sha256 hash`** — known, harmless
  git-archive repackaging drift for a few pinned commits.
  `fix_and_retry_buildroot.sh` repairs it automatically; if it still fails,
  check `/tmp/buildroot_autoretry_*.log` for a different cause.
- **`dfu-util -l` shows nothing** — you didn't stop autoboot in time, or
  `run dfu_mmc` wasn't accepted. (Prefer [flashing over SSH](flashing.md#option-c--over-ssh-from-the-running-board-no-card-removal) anyway.)
- **You moved the checkout and Buildroot fails with `cp: cannot stat`** —
  Buildroot's `output/` is **not relocatable**; autotools bakes absolute paths
  into thousands of generated files. Discard the stale build state (the
  download cache is unaffected):
  ```bash
  # run from: firmware/
  rm -rf src/buildroot/output
  ./scripts/build_all.sh
  ```

Still stuck? [Open an issue](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/new/choose) — the templates ask for
the details that actually speed up debugging. See also
[CONTRIBUTING.md](../CONTRIBUTING.md).
