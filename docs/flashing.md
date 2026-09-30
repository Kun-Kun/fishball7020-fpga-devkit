# Flashing the board, and checking what it runs

How to get a build onto the board (four ways), and how to confirm afterwards
that the board is running it. Building comes first:
[Building your own firmware](building.md).

**Contents**

- [Boot modes (BOOT DIP switch)](#boot-modes-boot-dip-switch) · [LEDs](#leds)
- [Flash the board](#flash-the-board): [A — SD card](#option-a--sd-card-always-works) · [B — DFU](#option-b--dfu-over-usb-no-disassembly) · [C — over SSH](#option-c--over-ssh-from-the-running-board-no-card-removal) · [C2 — a second card](#option-c2--a-second-card-when-you-do-not-want-to-risk-the-first) · [D — JTAG](#option-d--jtag-temporary-but-the-fastest-hdl-loop)
- [Recovering the factory firmware](#if-things-go-wrong-recovering-the-factory-firmware)
- [Verify your build is actually running](#verify-your-build-is-actually-running): which USB port is which, and the serial console

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
| **SD card** | `0` (GND) | `0` (GND) | Boots `BOOT.bin` from the microSD card: **factory default, what the devkit needs** |
| **QSPI flash** | `1` (VCC3V3) | `0` (GND) | Boots from the onboard 16 MiB flash instead |
| **JTAG** | `1` (VCC3V3) | `1` (VCC3V3) | Debugging and flashing over JTAG |

`1` means the slider is pushed toward the **`ON`** marking. **Change it only
with the board powered off**: the mode is read at power-on.

SD-card boot never writes the QSPI flash, so whatever is on that chip is left
alone. The distributor's write-up lists QSPI as the default, but boards ship in
SD mode: check the switch, not the documentation.

### LEDs

| LED | Meaning |
|---|---|
| `PWR` | Power present |
| `DONE` | FPGA configured: the same DONE that Vivado reports as `End of startup status: HIGH` |
| `USER` | Driven by Linux (PS GPIO); blinks via the kernel heartbeat trigger ([how to control it](user-led.md)) |

## Flash the board

| | When | Updates `BOOT.bin` (the bitstream)? |
|---|---|---|
| **C: `./devkit flash`** | most of the time; the board is running | yes |
| **A: SD card** | the board no longer boots, or a new Debian card | yes |
| **C2: a second card** | trying a `BOOT.bin` you are unsure of | yes, on the spare card |
| **D: JTAG** | trying FPGA changes in seconds; gone at power-off | no |
| B: DFU | not recommended on this board | no |

### Option A — SD card (always works)

**`firmware/` (Buildroot):** one FAT32 partition, five files.

```bash
# run from: firmware/
cp output/{BOOT.bin,devicetree.dtb,uEnv.txt,uImage,uramdisk.image.gz} /path/to/sd-card/
```

**`firmware-modern/` (Debian):** two partitions, so the card has to be
partitioned and the root filesystem unpacked. One command does all of it:

```bash
# run from: the repo root. DESTROYS everything on the card
./devkit write-card --target modern --dry-run /dev/sdX    # checks the device, writes nothing
sudo ./devkit write-card --target modern /dev/sdX
```

It makes a 128 MB FAT partition for the four boot files and an ext4 partition
for the rest of the card, unpacks the Debian tarball into it, and writes a
`uEnv.txt` that tells U-Boot to boot from the second partition rather than a
ramdisk. It refuses any disk that is not removable, but **check the device name
yourself**: this is the one command in this repository that can destroy data
you care about. (`firmware-modern/debian/write-card.sh` is the script it runs.)

Either way: eject, insert, power-cycle. If the board comes up with old
firmware or not at all, check that the `BOOT` switch is in SD mode: a board in
QSPI mode ignores the card entirely, which looks exactly like a failed build.

### Option B — DFU over USB (no disassembly)

**Do not use DFU on this board.** It has bricked units. This section is kept
for reference only; Option C does everything DFU does, can also update
`BOOT.bin`, and backs up and checks as it goes.

DFU (USB Device Firmware Upgrade) is built into U-Boot and can push `uImage`,
`devicetree.dtb` and `uramdisk.image.gz` onto the card over the USB cable. It
**cannot** update `BOOT.bin`: there is no DFU target for the
bitstream/FSBL/U-Boot.

1. Open a serial console (see [below](#verify-your-build-is-actually-running)),
   power-cycle, press any key within 3 s to stop at `Pluto>`.
2. `Pluto> run dfu_mmc`. The board now waits for transfers, printing nothing.
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

If the board still boots, it can rewrite its own SD card: mount the FAT boot
partition, replace the files, reboot. This is the only remote option that can
update the FPGA bitstream.

```bash
# run from: the repo root
./devkit flash              # BOOT.bin + uImage
./devkit flash --all        # every file on the boot partition (factory target only)
./devkit flash --boot-only  # BOOT.bin only: an HDL or bitstream change
./devkit flash --kernel-only
./devkit flash --dtb-only
```

It backs up the current files, checks the md5 of each new file on the board
before swapping it in, unmounts cleanly and reboots. The previous files stay on
the card as `*.prev` and on your disk in `firmware/.flash-backups/<stamp>/`. A
kernel that does not boot is undone by putting the `.prev` file back from a
card reader; a kernel that boots but misbehaves is undone with another
`--kernel-only`.

**Which build it flashes:** `firmware/output/` by default. `--target modern`
flashes `firmware-modern/output/` instead (it sets `FW_OUTPUT` for
`tools/flash.sh`). The files have the same names, so this flag is the only thing
that distinguishes them. `--all` and `--rootfs-only` are refused for the modern
target, because the Debian root cannot be swapped over the network; write a
card instead (Option A).

```bash
# run from: the repo root. Flash the Linux 6.12 kernel
./devkit flash --target modern --kernel-only
```

**Where the boot partition is depends on the root filesystem.** On Buildroot,
`/dev/mmcblk0p1` is left **unmounted**, so you mount it yourself. On Debian it
is **already mounted at `/boot`**, and mounting it a second time fails.
`./devkit flash` handles both by bind-mounting an existing mount instead of
mounting the device again.

By hand, the same steps:

```bash
# run from: firmware/  (on your HOST; BOARD is the running board)
BOARD=root@192.168.2.1

# 0. Find the boot partition: /boot on Debian; on Buildroot, mount it at /tmp/sd.
SD=$(ssh $BOARD 'findmnt -n -o TARGET -S /dev/mmcblk0p1 || { mkdir -p /tmp/sd && mount /dev/mmcblk0p1 /tmp/sd && echo /tmp/sd; }')
echo "$SD"

# 1. Back up what is on the card now. This is your way back.
ssh $BOARD "cat $SD/BOOT.bin" > BOOT.bin.rollback
ssh $BOARD "md5sum $SD/BOOT.bin"
md5sum BOOT.bin.rollback                      # the two must match

# 2. Copy the new file in beside the old one, and check it before swapping.
scp output/BOOT.bin $BOARD:$SD/BOOT.bin.new
ssh $BOARD "md5sum $SD/BOOT.bin.new"          # must match: md5sum output/BOOT.bin

# 3. Swap, flush, reboot. (If you mounted /tmp/sd yourself, unmount it before rebooting.)
ssh $BOARD "cd $SD && cp BOOT.bin BOOT.bin.prev && mv BOOT.bin.new BOOT.bin && sync && reboot"
```

The board is back in about 40 seconds.

> **Do the backup step.** A bad `BOOT.bin` means the board does not boot, and
> then this option is gone: recovery needs a card reader. Check the md5
> *before* the `mv`, unmount cleanly so the FAT metadata is written, and keep
> the rollback copy until the new firmware has proved itself.

### Option C2 — a second card, when you do not want to risk the first

The safest way to try a `BOOT.bin` you are unsure of (a new FSBL, especially)
is to leave the board's own card alone and boot a different one:

```bash
# run from: the repo root, with a blank card in a reader
./tools/make-sd-card.sh /dev/sdX --dry-run            # check the target first
./tools/make-sd-card.sh /dev/sdX --boot-bin /path/to/BOOT.bin
```

It writes the **factory** layout (one FAT32 partition with the five files),
which boots the Buildroot RAM disk and needs no second partition. Power the
board off, swap cards, power on. If it does not boot, swap back; nothing was
written to the card that works. The script refuses anything that is not a
removable USB/MMC whole disk, refuses a disk holding `/` or `/home`, refuses a
mounted one, and makes you type the device name back.

It also leaves you with a bootable spare card, which every recovery note on
this page assumes you can make.

### Option D — JTAG (temporary, but the fastest HDL loop)

JTAG is a hardware debug interface. Through it you can push a bitstream straight
into the FPGA in seconds instead of a full rebuild and flash. It is
**volatile** (gone at power-off) and does **not** update `BOOT.bin`: it is for
testing, not deployment. Use the **debug port** (JTAG is interface 0), and keep
the USB 2.0 port connected too.

**One-time setup.** Vivado ships udev rules for Digilent cables but does not
install them; without them libusb cannot claim the device and Vivado reports
`ERROR: [Labtoolstcl 44-199] No matching targets found`. Run this **in a real
terminal on the machine the board is plugged into**: `sudo` needs a TTY, and
rules installed inside a VM do not affect the host.

```bash
# run on your HOST, from anywhere
sudo cp /tools/Xilinx/Vivado/2022.2/data/xicom/cable_drivers/lin64/install_script/install_drivers/*.rules \
        /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Unplug and replug the debug cable, then check (no sudo needed): two `.rules`
files in `/etc/udev/rules.d/`, and permissions `crw-rw-rw-` on the USB node.
Confirm Vivado sees it with `open_hw_manager; connect_hw_server;
get_hw_targets; open_hw_target; get_hw_devices`. You want the Digilent cable,
then `arm_dap_0 xc7z020_1`.

**Keep BOTH cables connected throughout.** The debug port powers the board and
the USB 2.0 port carries the network. The bitstream is volatile, so unplugging
one to "move over" cuts power and loses it.

**Never program while Linux is running.** Its drivers are bound to the *old*
programmable logic (PL, the FPGA half of the chip); swapping it underneath them
hangs the system.

### D1. Quick method — Hardware Manager, halted at U-Boot

1. Open the debug UART, power-cycle, press a key within 3 s to stop at `Pluto>`.
   The FSBL has configured the processing system (PS, the ARM half) and enabled
   the level shifters; Linux has claimed nothing.
2. Program. In the GUI: **Open Hardware Manager → Auto Connect → right-click
   `xc7z020_1` → Program Device**. Or scripted:

   ```tcl
   # run on your HOST, in the Vivado Tcl console (the working directory does
   # not matter: the .bit is given by absolute path below)
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
means the bitstream did not load.

**Limitation.** On Zynq the PS↔PL level shifters and PL resets are managed by
*software* (`ps7_post_config`), not by programming. Reloading the PL under a PS
set up for the previous bitstream can leave the AXI bus in an undefined state.
That is usually fine when the AXI topology has not changed; otherwise use D2.

### D2. Robust method — full JTAG bootstrap (ADI's own flow)

This brings the whole board up from JTAG, so the PS is initialised *for the
bitstream you are loading*, in the right order:

```tcl
# run on your HOST: xsdb run-jtag.tcl, from firmware/src/hdl/projects/pluto
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

The order matters. `ps7_init` configures DDR, clocks and pin multiplexing; the
bitstream goes in next; **`ps7_post_config` must come after it**, because it
enables the level shifters and releases the PL resets. ADI's shipped script has
the `fpga` line commented out, because it was written for flashing U-Boot
without a new bitstream. Everything the script needs comes from a normal
build. When the design works, rebuild and flash with Option A or C so it
persists.

### If things go wrong: recovering the factory firmware

The distributor publishes the board's prebuilt factory firmware:
**[`OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR`](https://github.com/OpenSourceSDRLab/PlutoSky_7020_AD936X_SDR)**.
Those binaries match a working unit's SD card byte for byte
([provenance](provenance.md)). Copy them onto a FAT32 card as in
[Option A](#option-a--sd-card-always-works).

Keep a local copy *before* experimenting. A rescue that needs the internet and a
third-party repository still being online is a weaker safety net than a folder
on your disk.

## Verify your build is actually running

**Before you flash**, check that the build makes sense. This takes a second;
flashing and rebooting take minutes.

```bash
# run from: the repo root
./devkit verify                  # is the build sane?
./devkit verify --board          # ...and is the board running it?
./devkit verify --require-board  # the same, but FAIL if the board is stale or unreadable
```

`--board` reports but does not change the exit status, because a board that is
switched off is not a fault in the build. Use `--require-board` in a script
that must fail on a stale card.

`./devkit verify` checks that `firmware/output/`'s five files are present and
not trivially small, that the bitstream is compressed (an uncompressed one
overflows the FSBL's on-chip memory and `BOOT.bin` silently fails to boot), and
that no setup endpoint fails timing. Then it prints what is in the design, so
you can see your change landed:

```
== FPGA design ==
  PASS  utilization report present
        DSP48s 94 / 220   Slice LUTs 12521 / 53200
        -> decimator on BOTH RX channels (default)
        block design: no rx_ddc
        RX decimator: both channels (patch 0021)
== bitstream ==
  PASS  compressed (2371856 B < 3.9 MB uncompressed)
== timing ==
  PASS  no failing setup endpoints
        WNS 0.215 ns over 54211 endpoints
```

Two other builds print differently, and `verify` names each:
`STOCK_RX_FILTER=1` gives `72 / 220` and `decimator on RX channel 0 only`, and
the optional channelizer gives `96 / 220` with `rx_ddc (Fs/4 shifter) is wired
in`. It exits non-zero on failure, so it works in scripts.

For the modern target the equivalent check is `firmware-modern/verify_dtb.py`,
which audits the built device tree against sixteen things the board needs. CI
runs it on every push.

`--board` answers a different question: it mounts the board's SD card and
compares every file against `output/` by checksum. A board whose card holds a
*different* build of the same size looks entirely normal, and every symptom of
that looks like "my change did not work". `--board` reports a stale board as
stale rather than as a bad build.

### Which USB port is which

| | **USB 2.0 (OTG) port** | **Debug port** |
|---|---|---|
| Enumerates as | `0456:b673` Analog Devices, typically `/dev/ttyACM*` (`-if03`) | `0403:6010` **Digilent Adept**, two `/dev/ttyUSB*` |
| Gives you | Network over USB (`192.168.2.1`), libiio, mass storage, a console | **JTAG** (`-if00`) and the board's **real UART console** (`-if01`) |
| Available | Only **after Linux boots**: a USB gadget created by the board's Linux | From **power-on**: real hardware, independent of software |

**For serial, use the debug port.** Its UART is the actual console (`ttyPS0`),
so you see FSBL → U-Boot → kernel → login. The OTG console appears only once
Linux is up, so you miss the whole boot, and see nothing at all if the board
fails to boot, which is when you need it most.

Find the port by its stable name rather than assuming a number:

```bash
# run on your HOST, from anywhere
ls -l /dev/serial/by-id/
#  ...Digilent_Adept_USB_Device_<serial>-if00-port0 -> ttyUSB0   <- JTAG
#  ...Digilent_Adept_USB_Device_<serial>-if01-port0 -> ttyUSB1   <- console
screen /dev/serial/by-id/usb-Digilent_Digilent_Adept_USB_Device_<serial>-if01-port0 115200
```

Press Enter for a login prompt; the credentials are **`root` / `analog`**
(change them with `device_passwd` on the board). Exit `screen` with `Ctrl-A`
then `k`, `y`.

**SSH works too** and is usually more convenient: the firmware runs dropbear,
reachable over the USB network or Ethernet with `ssh root@192.168.2.1`. That
needs the **USB 2.0 port**; the debug port carries no network.

### Confirm the version on the board

```bash
# run on the board (over ssh or the serial console)
cat /opt/VERSIONS
```

It prints a `device-fw <git-hash>` line plus one line per component. The
Buildroot target's is generated by `build_all.sh`; the Debian target's by its
Containerfile, followed by every installed package at its exact version.
Upstream firmware hardcodes `fw_version=v0.38`, so a git hash there means you
are running your own build. The same value shows in `iio_info` as
`fw_version`, where `hw_model` should read `FISH Ball PlutoSDR Rev.A
(Z7020-AD9361)`.
