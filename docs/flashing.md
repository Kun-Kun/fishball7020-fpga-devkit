# Flashing the board, and checking what it runs

How to get a build onto the board, four ways, and how to prove afterwards that
the board is really running it. Building comes first: [Building your own firmware](building.md).

**Contents**

- [Boot modes (BOOT DIP switch)](#boot-modes-boot-dip-switch) · [LEDs](#leds)
- [Flash the board](#flash-the-board): [A — SD card](#option-a--sd-card-always-works) · [B — DFU](#option-b--dfu-over-usb-no-disassembly) · [C — over SSH](#option-c--over-ssh-from-the-running-board-no-card-removal) · [C2 — a second card](#option-c2--a-second-card-when-you-do-not-want-to-risk-the-first) · [D — JTAG](#option-d--jtag-temporary-but-the-fastest-hdl-loop)
- [Recovering the factory firmware](#if-things-go-wrong-recovering-the-factory-firmware)
- [Verify your build is actually running](#verify-your-build-is-actually-running) — including which USB port is which, and the serial console

## Boot modes (BOOT DIP switch)

A two-position switch marked **`BOOT`**, next to `RST` between the `USB2.0` and
`DEBUG` ports, picks where the board boots from. Boards ship in SD mode, which
is what the devkit needs. If a freshly flashed card seems to do nothing, check
this first.

<table>
<tr>
<td align="center"><img src="img/boot-sd-00.jpg" alt="BOOT switch set to 0 0 for SD card boot" width="250"><br><b>SD card — <code>0 0</code></b><br><sub>factory default, used by the devkit</sub></td>
<td align="center"><img src="img/boot-qspi-10.jpg" alt="BOOT switch set to 1 0 for QSPI flash boot" width="250"><br><b>QSPI flash — <code>1 0</code></b><br><sub>boots from the onboard flash</sub></td>
<td align="center"><img src="img/boot-jtag-11.jpg" alt="BOOT switch set to 1 1 for JTAG mode" width="250"><br><b>JTAG — <code>1 1</code></b><br><sub>debugging and flashing</sub></td>
</tr>
</table>

<sub>Switch photographs from the distributor's
<a href="https://blog.opensourcesdrlab.com/archives/PlutoSky-R1">PlutoSky R1 write-up</a>.</sub>

| Mode | SW1 | SW2 | What it does |
|---|---|---|---|
| **SD card** | `0` (GND) | `0` (GND) | Boots `BOOT.bin` from the microSD card — **factory default, what the devkit needs** |
| **QSPI flash** | `1` (VCC3V3) | `0` (GND) | Boots from the onboard 16 MiB flash instead |
| **JTAG** | `1` (VCC3V3) | `1` (VCC3V3) | Debugging and flashing over JTAG |

`1` means the slider is pushed toward the **`ON`** marking. **Change it only
with the board powered off** — the mode is sampled at power-on.

SD-card boot never writes the QSPI flash, so whatever is on that chip is
unaffected. The distributor's write-up lists QSPI as default; boards observed
in practice ship in SD mode — check the switch, not the documentation.

### LEDs

| LED | Meaning |
|---|---|
| `PWR` | Power present |
| `DONE` | FPGA configured — the same DONE that Vivado reports as `End of startup status: HIGH` |
| `USER` | Driven by Linux (PS GPIO); blinks via the kernel heartbeat trigger — [how to control it](user-led.md) |

## Flash the board

**Most of the time, use `./devkit flash`** ([Option C](#option-c--over-ssh-from-the-running-board-no-card-removal)):
it works over the network while the board is running, can replace everything
including the FPGA bitstream, and backs up and verifies as it goes. Reach for
the SD card (A) when the board no longer boots, and JTAG (D) when you want to
try FPGA changes in seconds.

### Option A — SD card (always works)

**`firmware/` (Buildroot)** — one FAT32 partition, five files:

```bash
# run from: firmware/
cp output/{BOOT.bin,devicetree.dtb,uEnv.txt,uImage,uramdisk.image.gz} /path/to/sd-card/
```

**`firmware-modern/` (Debian)** — two partitions, so it is not a copy; the card
has to be partitioned and the rootfs unpacked. One script does all of it:

```bash
# run from: firmware-modern/debian/   — DESTROYS everything on the card
sudo ./write-card.sh /dev/sdX
```

It makes a 128 MB FAT partition for the four boot files, an ext4 partition for
the rest of the card, unpacks the Debian tarball into it, and writes a `uEnv.txt`
that tells U-Boot to boot from the second partition rather than a ramdisk. It
refuses to run against a disk that looks like your system disk, but **check the
device name yourself** — this is the one command in this repository that can
destroy data you care about.

Either way: eject, insert, power-cycle. **This is the only option that updates
everything including the bitstream**, so it is the one for any HDL change. If the
board comes up with old firmware or not at all, check the `BOOT` switch is in SD
mode — a board in QSPI mode ignores the card entirely, which looks exactly like a
failed build.

### Option B — DFU over USB (no disassembly)

Kept for reference — **prefer Option C**, which does everything DFU does, can
also update `BOOT.bin`, and backs up and verifies as it goes. U-Boot has USB DFU
built in and can push `uImage`, `devicetree.dtb` and `uramdisk.image.gz` onto
the card over the USB cable, but it **cannot** update `BOOT.bin` — there
is no DFU target for the bitstream/FSBL/U-Boot — and DFU has bricked units on
this board.

1. Open a serial console (see [below](#verify-your-build-is-actually-running)),
   power-cycle, press any key within 3 s to stop at `Pluto>`.
2. `Pluto> run dfu_mmc` — the board now waits for transfers, printing nothing.
3. From your host:
   ```bash
   # run from: firmware/output/  (on your HOST, not the board)
   dfu-util -l   # confirms you can see the three targets
   dfu-util -D uImage             -a uImage
   dfu-util -D devicetree.dtb     -a devicetree.dtb
   dfu-util -D uramdisk.image.gz  -a uramdisk.image.gz
   ```
4. **Ctrl+C** on the console to exit the DFU loop, then `Pluto> reset`.

### Option C — over SSH, from the running board (no card removal)

If the board still boots, it can rewrite its own SD card: mount the FAT
partition, replace `BOOT.bin`, reboot. **This is the only remote option that can
update the FPGA bitstream.**

> **Where that partition is depends on the rootfs**, and getting it wrong is how
> this went wrong once. On Buildroot `/dev/mmcblk0p1` is left **unmounted**, so
> you mount it yourself. On Debian it is **already mounted at `/boot`**, and
> mounting it a second time on `/tmp/sd` fails — `./devkit flash` handles both by
> bind-mounting an existing mount instead of re-mounting the device.

**Use the script** — it does the backup, the checksum verification before the
swap, the clean unmount and the reboot, and keeps the previous firmware both on
the card and on your disk:

```bash
# run from: the repo root
./devkit flash              # BOOT.bin + uImage
./devkit flash --all        # every file on the boot partition
./devkit flash --boot-only  # just the bitstream
```

**Which build does it flash?** `firmware/output/` by default. Set `FW_OUTPUT` to
flash the other firmware target instead — the files are named the same, so this is
the only thing that distinguishes them:

```bash
# run from: the repo root - flash the Linux 6.12 kernel
FW_OUTPUT=$PWD/firmware-modern/output ./tools/flash.sh --kernel-only
```

Either way the previous file stays on the card as `*.prev` and in
`firmware/.flash-backups/<stamp>/`, so a kernel that does not boot is one
card-reader trip away from being undone — and a kernel that *does* boot but
misbehaves is one `--kernel-only` away.

What it does, if you would rather do it by hand:

```bash
# run from: firmware/   (BOARD is the running board)
BOARD=root@192.168.2.1

# 0. Find the boot partition. On Debian it is already at /boot; on Buildroot
#    nothing has mounted it, so mount it. This one line covers both.
ssh $BOARD 'SD=$(findmnt -n -o TARGET -S /dev/mmcblk0p1) || { mkdir -p /tmp/sd; mount /dev/mmcblk0p1 /tmp/sd; SD=/tmp/sd; }; echo $SD'
# ... use that path as $SD below; it is /boot on Debian and /tmp/sd on Buildroot.

# 1. Back up what is on the card RIGHT NOW - this is your way back.
ssh $BOARD 'cat /boot/BOOT.bin' > BOOT.bin.rollback
ssh $BOARD 'md5sum /boot/BOOT.bin'
md5sum BOOT.bin.rollback                      # the two must match

# 2. Copy the new one in beside the old, then verify before swapping.
scp output/BOOT.bin $BOARD:/boot/BOOT.bin.new
ssh $BOARD 'md5sum /boot/BOOT.bin.new'        # must match md5sum output/BOOT.bin

# 3. Swap, flush, reboot. Unmount first if YOU mounted it.
ssh $BOARD 'cd /boot && cp BOOT.bin BOOT.bin.stockbak && mv BOOT.bin.new BOOT.bin && sync && reboot'
```

The board is back in about 40 seconds.

> **Do the backup step.** A bad `BOOT.bin` means the board does not boot, and
> then this option is gone — recovery needs a card reader. Verify the md5
> *before* the `mv`, unmount cleanly so FAT metadata is flushed, and keep the
> rollback until the new firmware has proved itself.

### Option C2 — a second card, when you do not want to risk the first

The safest way to try a `BOOT.bin` you are unsure of — a new FSBL, especially —
is to leave the board's own card alone and boot a different one:

```bash
# run from: the repo root, with a blank card in a reader
./tools/make-sd-card.sh /dev/sdX --dry-run            # check the target first
./tools/make-sd-card.sh /dev/sdX --boot-bin /path/to/BOOT.bin
```

It writes the **factory** layout — one FAT32 partition with the five files —
which boots the Buildroot RAM disk and needs no second partition. Power the
board off, swap cards, power on. If it does not boot, swap back; nothing was
written to the card that works. The script refuses anything that is not a
removable USB/MMC whole disk, refuses a disk holding `/` or `/home`, refuses a
mounted one, and makes you type the device name back.

That leaves you with a bootable spare card, which is the thing every recovery
note on this page assumes you can make.

### Option D — JTAG (temporary, but the fastest HDL loop)

Push a bitstream straight into the FPGA over JTAG — seconds instead of a full
rebuild. It is **volatile** (gone on power-cycle) and does **not** update
`BOOT.bin`: for testing, not deployment. Use the **debug port** (JTAG is
interface 0), and keep the USB 2.0 port connected too.

**One-time setup.** Vivado ships udev rules for Digilent cables but doesn't
install them; without them libusb can't claim the device and Vivado reports
`ERROR: [Labtoolstcl 44-199] No matching targets found`. Run this **in a real
terminal on the machine the board is plugged into** — `sudo` needs a TTY, and
rules installed inside a VM don't affect the host:

```bash
# run on your HOST, from anywhere
sudo cp /tools/Xilinx/Vivado/2022.2/data/xicom/cable_drivers/lin64/install_script/install_drivers/*.rules \
        /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Unplug and replug the debug cable, then verify (no sudo needed): two `.rules`
files in `/etc/udev/rules.d/`, and permissions `crw-rw-rw-` on the USB node.
Confirm Vivado sees it with `open_hw_manager; connect_hw_server;
get_hw_targets; open_hw_target; get_hw_devices` — you want the Digilent cable,
then `arm_dap_0 xc7z020_1`.

**Keep BOTH cables connected throughout.** The debug port powers the board and
the USB 2.0 port carries the network; since the bitstream is volatile,
unplugging to "move over" would cut power and lose it.

**Never program while Linux is running.** Its drivers are bound to the *old*
PL; swapping underneath them hangs the system.

### D1. Quick method — Hardware Manager, halted at U-Boot

1. Open the debug UART, power-cycle, press a key within 3 s to stop at `Pluto>`.
   The FSBL has configured the PS and enabled the level shifters; Linux has
   claimed nothing.
2. Program — GUI: **Open Hardware Manager → Auto Connect → right-click
   `xc7z020_1` → Program Device**. Or scripted:

   ```tcl
   # run on your HOST, in the Vivado Tcl console (the working directory does
   # not matter - the .bit is given by absolute path below)
   open_hw_manager
   connect_hw_server
   open_hw_target
   current_hw_device [get_hw_devices xc7z020_1]
   set_property PROGRAM.FILE \
     {<repo>/firmware/src/hdl/projects/pluto/pluto.runs/impl_1/system_top.bit} \
     [current_hw_device]
   program_hw_devices [current_hw_device]
   ```

3. Back at `Pluto>`, type `boot`.

Success prints `INFO: [Labtools 27-3164] End of startup status: HIGH`. `LOW`
means the bitstream didn't take.

**Caveat.** On Zynq the PS↔PL level shifters and PL resets are managed by
*software* (`ps7_post_config`), not by programming. Re-loading the PL under a
PS set up for the previous bitstream can leave AXI in an undefined state —
usually fine when the AXI topology hasn't changed, otherwise use D2.

### D2. Robust method — full JTAG bootstrap (ADI's own flow)

Brings the whole board up from JTAG so the PS is initialised *for the bitstream
you are loading*, in the right order:

```tcl
# xsdb run-jtag.tcl     (run from: firmware/src/hdl/projects/pluto)
connect
target 2
rst
source ps7_init.tcl
ps7_init
fpga -f pluto.runs/impl_1/system_top.bit
ps7_post_config
dow ../../../u-boot-xlnx/u-boot
con
```

Ordering is the point: `ps7_init` configures DDR/clocks/MIO, the bitstream goes
in next, and **`ps7_post_config` must come after it** — that's what enables the
level shifters and releases the PL resets. ADI's shipped script has the `fpga`
line commented out because their use case was flashing U-Boot without a new
bitstream. Everything needed comes from a normal build. When the design works,
rebuild and flash via Option A so it persists.

### If things go wrong: recovering the factory firmware

If you skipped the backup or lost it, the distributor publishes the board's
prebuilt factory firmware:
**[`OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR`](https://github.com/OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR)**

This is a verified fallback, not a guess: those binaries were compared
byte-for-byte against a working unit's SD card during this project. Copy them
onto a FAT32 card as in [Option A](#option-a--sd-card-always-works). Keep a
local copy *before* experimenting — a rescue that needs the internet and a
third-party repo still being online is a weaker net than a folder on your disk.

## Verify your build is actually running

**Before you flash**, check the build made sense — this costs a second, where
flashing and rebooting costs minutes:

```bash
# run from: the repo root
./devkit verify            # is the build sane?
./devkit verify --board    # ...and is the board actually running it?
# --board reports; it does not change the exit status, because a board that is
# off is not a fault in the build. For a gate that must FAIL on a stale or
# unreadable card, use --require-board instead.
```

It asserts `firmware/output/`'s five files are present and non-trivial, that the
bitstream is
compressed (an uncompressed one overflows the FSBL's OCM and `BOOT.bin`
silently fails to boot), and that no setup endpoint fails timing — then prints
what is actually in the design, so you can see your change landed. For the modern
target the equivalent check is `firmware-modern/verify_dtb.py`, which audits the
built device tree against sixteen things the board needs, and CI runs it on every
push:

```
== FPGA design ==
  PASS  utilization report present
        DSP48s 72 / 220   Slice LUTs 11896 / 53200
        -> stock filter
        block design: stock RX path, no rx_ddc
== bitstream ==
  PASS  compressed (2367948 B < 3.9 MB uncompressed)
== timing ==
  PASS  no failing setup endpoints
        WNS 0.205 ns over 48263 endpoints
```

(With the optional channelizer applied you would see `96 / 220` DSPs and
`rx_ddc (Fs/4 shifter) is wired in` instead.)

It exits non-zero on failure, so it works in scripts.

`--board` answers a different question: it mounts the board's SD card and
compares every file against `output/` by checksum. Worth knowing because a
board whose card holds a *different* build of the same size looks entirely
normal, and every symptom of that is indistinguishable from "my change did not
work". A stale board is reported as such rather than as a bad build.

**Which USB port is which** — the two do completely different things:

| | **USB 2.0 (OTG) port** | **Debug port** |
|---|---|---|
| Enumerates as | `0456:b673` Analog Devices, typically `/dev/ttyACM*` (`-if03`) | `0403:6010` **Digilent Adept**, two `/dev/ttyUSB*` |
| Gives you | Network-over-USB (`192.168.2.1`), libiio, mass storage, a console | **JTAG** (`-if00`) and the board's **real UART console** (`-if01`) |
| Available | Only **after Linux boots** — a USB gadget created by the board's Linux | From **power-on** — real hardware, independent of software |

**For serial, use the debug port**: its UART is the actual console (`ttyPS0`),
so you see FSBL → U-Boot → kernel → login. The OTG console only appears once
Linux is up, so you miss the whole boot — and see nothing at all if the board
fails to boot, which is exactly when you need it.

Find the port by its stable name rather than assuming a number:

```bash
# run on your HOST, from anywhere
ls -l /dev/serial/by-id/
#  ...Digilent_Adept_USB_Device_<serial>-if00-port0 -> ttyUSB0   <- JTAG
#  ...Digilent_Adept_USB_Device_<serial>-if01-port0 -> ttyUSB1   <- console
screen /dev/serial/by-id/usb-Digilent_Digilent_Adept_USB_Device_<serial>-if01-port0 115200
```

Press Enter for a login prompt; credentials are **`root` / `analog`** (change
with `device_passwd` on the board). Exit `screen` with `Ctrl-A` then `k`, `y`.

**SSH works too** and is usually more convenient — the firmware runs dropbear,
reachable over the USB network or Ethernet at `ssh root@192.168.2.1`. That
needs the **USB 2.0 port**; the debug port carries no network.

Then confirm your build is running, **on the board**:

```
# on the BOARD (inside the screen session)
cat /opt/VERSIONS
```

It prints a `device-fw <git-hash>` line plus one per component — generated by
`build_all.sh` on the Buildroot target, and by the Containerfile on the Debian
one, where it is followed by every installed package at its exact version.
Upstream firmware hardcodes `fw_version=v0.38` — anything else (a real git hash)
proves you are running your own build. The same value
shows in `iio_info` as `fw_version`, where `hw_model` should read `FISH Ball
PlutoSDR Rev.A (Z7020-AD9361)`.
