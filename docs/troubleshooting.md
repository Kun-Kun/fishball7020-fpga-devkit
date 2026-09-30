# Troubleshooting

Known problems, by symptom, with the cause and the fix. If the radio itself
misbehaves rather than the build, run the [self-test](../tools/selftest/README.md)
first.

**Contents:** [The board](#the-board) · [Building](#building) · [Flashing](#flashing)

## The board

### The board stops responding after a while

**Symptom.** ssh, libiio and even ping stop, but the board is still enumerated
on USB. Before it stops, the kernel log shows `ad9361 spi0.0: Calibration
TIMEOUT` repeating, then `Failed to find suitable dividers: ADC clock below
limit`, then a plain `echo ... > .../in_voltage_sampling_frequency` blocks
forever. Afterwards nothing responds (not ssh, not libiio over the network or
USB, not the `ttyACM0` gadget console) and only a physical replug clears it.
It can run healthy for hours, then wedge within a minute of real work.

**Cause.** Not enough power. On laptop USB bus power alone, a board with a
power amplifier browns out under sustained use. The host's kernel log tells a
brownout from a board fault: when the board drops, devices on a **different
root port** of the host drop with it a second later and re-enumerate together,
which no fault on the board can cause. `device descriptor read/64, error -71`
and `error -110` are the same signature.

**Fix.** The board has two USB connectors. Put the second cable on a **mains
charger**, not another port on the same laptop, which shares the same power
budget. To confirm, run `./devkit selftest`: on bus power it can wedge the
board at the 4 MHz `set_rate` in `test_receiver`; on mains it reports
`24 passed, 0 failed, HEALTHY`, with no Calibration TIMEOUTs.

### ssh works, but nothing can open the radio (Debian root)

**Symptom.** `iio_info -u ip:192.168.2.1` fails and SDR++ finds no device, but
ssh and the console work.

**Cause.** `iiod` (the daemon that serves the radio over the network) is held
back when the boot-time transmitter mute could not be confirmed. It
`Requires=` `fishball-rf-quiesce`, so the board comes up with no SDR service
rather than with a possibly unmuted transmitter. The network and console come
up anyway.

**Fix.** Ask why:

```bash
# run on the board
journalctl -b -u fishball-rf-quiesce -u iiod
```

Fix what it names (usually `ad9361-phy` missing, meaning the FPGA or device
tree), then `systemctl start iiod`, or reboot. Starting `iiod` re-runs the
quiesce first and starts `iiod` only if it passes; USB libiio comes back with
it. **Never run `/usr/sbin/iiod` directly**: that is the one way around the
check.

### SDRangel lists the board as `PlutoSDR0 TBD` and will not open it

**Cause.** SDRangel identifies Plutos by serial number. Firmware built without
patch `0001` reports an empty one, because this board's W25Q128 flash never
emits the `SPI-NOR-UniqueID` line the boot script looks for.

**Fix.** Rebuild with the current `patches/` and reflash; the board mints a
persistent serial on first boot. If SDRangel is a snap, also run
`sudo snap connect sdrangel:raw-usb`.

## Building

### U-Boot fails with `unrecognized -march target: armv5`

**Symptom.** `arm-linux-gnueabihf-gcc: error: unrecognized -march target:
armv5`, when you run U-Boot's `make` yourself with a hard-float compiler.

**Cause.** U-Boot tests whether the compiler accepts `-march=armv7-a`. A
hard-float compiler refuses that, because armv7-a on its own names no FPU, so
U-Boot falls back to `-march=armv7` and then `-march=armv5`, which GCC rejects.
Nothing here is ARMv5.

**Fix.** Pass `CC="arm-linux-gnueabihf-gcc -mfloat-abi=soft"` to U-Boot's
`make`. U-Boot is built soft-float anyway, so the code is the same.
`./devkit build` does this for you on both targets.

### `vivado` fails to start, or reports missing shared libraries

**Cause.** You sourced Vivado's `settings64.sh` instead of
`tools/env-vivado.sh`, which supplies the old libraries Vivado 2022.2 needs.

**Fix.** `source tools/env-vivado.sh`. See
[Install Vivado 2022.2](building.md#install-vivado-20222).

### Vivado dies mid-synthesis with `tcmalloc: large alloc 115875935977472 bytes`

**Symptom.** `tcmalloc: large alloc …` or `realloc(): invalid pointer`, in a
container.

**Cause.** That 115 TB request is an integer underflow. Vivado's licence
manager `dlopen`s `libudev.so.1` and enumerates every device to fingerprint the
host, by which point Vivado's bundled tcmalloc has replaced `malloc`
process-wide while libudev still frees through glibc.

**Fix.** `./devkit container` loads a stub libudev that answers with an empty
list; see [Building in a container](building-in-a-container.md#vivado-dies-in-synthesis-with-a-heap-error).
Do **not** silence it with `MALLOC_CHECK_`: that hides real heap corruption in
the tool that builds your bitstream.

### The FSBL stage fails with a bare `Channel closed` from `xsct`

**Cause.** An older checkout that still builds the FSBL (the first-stage boot
loader) with Vitis's `xsct`. Vitis is Eclipse-based and needs GTK3 and the SWT
libraries.

**Fix.** Update: the FSBL is now built from AMD's embeddedsw with
`gcc-arm-none-eabi`, and nothing starts Vitis. On an old checkout, install GTK3
and the SWT libraries alongside Vivado's GTK2.

### The kernel build fails with `GLIBC_2.xx not found` in a `gcc-plugins` step

**Cause.** You sourced `env-vivado.sh` in the same shell you then built the
kernel in; it puts Xilinx toolchain directories on `PATH`, and they conflict.

**Fix.** Build the kernel in a fresh shell. `build_all.sh` keeps the two apart
by itself.

### U-Boot stage [3/7] fails at `tools/aisimage.o` with `conflicting types for 'fdt64_t'`

**Symptom.** A wall of redefinitions naming `/usr/include/libfdt.h`.

**Cause.** Your host has libfdt's headers installed (`libfdt-dev` on
Debian/Ubuntu; on Arch they come with `dtc`, which this repository requires).
U-Boot's `tools/Makefile` searches its own `include/` *after* the system
directories, so the system header wins and disagrees with U-Boot about
`fdt32_t`/`fdt64_t`.

**Fix.** Patch `0020` fixes it; `./devkit setup` applies it. Do **not**
uninstall the package: on Arch that would take `dtc` with it.

### Buildroot fails with `has wrong sha256 hash`

**Cause.** Known, harmless git-archive repackaging drift for a few pinned
commits.

**Fix.** `fix_and_retry_buildroot.sh` repairs it automatically. If it still
fails, check `/tmp/buildroot_autoretry_*.log` for a different cause.

### Buildroot fails with `cp: cannot stat` after you moved the checkout

**Cause.** Buildroot's `output/` is **not relocatable**: autotools writes
absolute paths into thousands of generated files.

**Fix.** Discard the stale build state (the download cache is unaffected):

```bash
# run from: firmware/
rm -rf src/buildroot/output
./scripts/build_all.sh
```

## Flashing

### `dfu-util -l` shows nothing

**Cause.** Autoboot was not stopped in time, or `run dfu_mmc` was not accepted.

**Fix.** Do not use DFU on this board; flash
[over SSH](flashing.md#option-c--over-ssh-from-the-running-board-no-card-removal)
instead.

### A freshly flashed card seems to do nothing, or the old firmware still runs

**Cause.** The `BOOT` DIP switch is not in SD mode, so the board ignores the
card; or the card holds a different build from the one you think.

**Fix.** Check the switch ([boot modes](flashing.md#boot-modes-boot-dip-switch)),
then `./devkit verify --board` to compare the card with your build.

## Still stuck?

[Open an issue](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/new/choose).
The templates ask for the details that speed up debugging. See also
[CONTRIBUTING.md](../CONTRIBUTING.md).
