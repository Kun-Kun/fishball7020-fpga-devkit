# How it works: from power-on to a running radio

What the files on the SD card are, and what happens between plugging the board
in and a login prompt; no FPGA or embedded-Linux knowledge assumed. To just
build and flash, the [README](../README.md) is enough; read this to understand
why the build has seven stages, or why one line of HDL (hardware description
language, the code that describes a circuit) means rebuilding `BOOT.bin`.

## The chip has two halves

On a PC, fixed hardware and firmware you never wrote (BIOS/UEFI) start the
operating system. On this board you build every layer, including the hardware.
The Zynq-7020 is two things in one package:

- **The PS ("Processing System")**: an ordinary ARM computer with two cores, a
  memory controller, USB, Ethernet, SD card and serial ports. It runs Linux.
- **The PL ("Programmable Logic")**: an **FPGA**, a sea of generic logic elements
  and reconfigurable wiring. You describe a circuit (in Verilog, or by wiring
  blocks in Vivado) and it is compiled into a **bitstream**, the configuration
  data that makes the blank fabric become that circuit.

The PL is where the radio lives: the interface to the AD9361 radio chip, the DMA
engines that move samples into memory, the digital filters. Your own HDL goes here.

## The chain

```
 BootROM  ──►  FSBL  ──►  bitstream  ──►  U-Boot  ──►  kernel + DTB  ──►  root filesystem
(in silicon)  (on-chip     (into the      (in DDR)      (in DDR)           (in RAM)
               RAM)         FPGA)
```

Each stage exists because the previous one physically cannot do the next job.

1. **BootROM**, burned into the silicon. It checks the boot pins (here: SD card),
   finds `BOOT.bin` and copies its first piece into **OCM** (on-chip memory, only
   256 KB). It cannot load Linux: the kernel alone is 4.5 MB, and the 1 GB of
   **DDR** main memory does not work until its controller is configured.
2. **FSBL ("First Stage Bootloader")**, a bare-metal program in those 256 KB:
   - **`ps7_init`** configures the DDR controller, clocks and pin multiplexing,
     after which main memory exists;
   - it **loads the bitstream into the PL**;
   - **`ps7_post_config`** enables the level shifters between PS and PL (they run
     at different voltages), after which the ARM side can reach your logic;
   - then it loads U-Boot into DDR and jumps to it. That order is why the
     [JTAG procedure](flashing.md#option-d--jtag-temporary-but-the-fastest-hdl-loop)
     looks the way it does.
3. **U-Boot**, a full bootloader with drivers, a scripting language and the
   `Pluto>` prompt (press a key during boot). It reads `uEnv.txt`, loads the
   kernel, device tree and (factory target) ramdisk into memory, patches things like MAC addresses into
   the device tree, and starts the kernel.
4. **The kernel.** `uImage` is Linux with a small U-Boot header (load address and
   checksum). The factory target runs 5.15 from the vendor's tree;
   [`firmware-modern/`](../firmware-modern/README.md) builds **6.12 LTS** from
   Analog Devices. A kernel swap changes one file and nothing in stages 1–3, so
   `./devkit flash --kernel-only` swaps kernels over the network in about six
   seconds, keeping the previous one on the card as `uImage.prev`.
5. **The device tree** (`devicetree.dtb`, "blob"). Nothing on this chip announces
   itself, so Linux is told what hardware exists and where: that the AD9361 is on
   SPI port 0, that the DMA engines live at `0x7c400000`. **The device tree must
   match the bitstream**: change what the FPGA contains and the description may
   need to change too.
6. **The root filesystem**, everything above the kernel: `/bin`, `/etc`, startup
   scripts, and `libiio`/`iiod`, which let your PC stream samples. This is where
   the two targets differ:

| | `firmware/` (factory) | `firmware-modern/` |
|---|---|---|
| what it is | `uramdisk.image.gz`, built by **Buildroot** | **Debian 13 (trixie) armhf** with systemd |
| where it lives | decompressed into **RAM** at boot | **ext4 on the second SD partition** |
| survives a reboot? | **no** — except `/mnt/jffs2` | **yes** — it is an ordinary disk |
| installing software | rebuild the whole image, reflash | `apt install` |
| init | busybox SysV, nine `S*` scripts | systemd units |
| size | ~6.7 MB compressed | ~363 MB on a 7.4 GB partition |

Buildroot's ramdisk is identical on every boot, so nothing changed last week can
explain today's behaviour, but edits on the board are lost at reboot. Debian keeps
edits, `apt` and persistent `journalctl` logs, at the cost of a bigger card and a
system that can drift from the repository. `/mnt/jffs2` lives in QSPI flash and
is mounted on both, but only Buildroot runs `/mnt/jffs2/autorun.sh`; a script
there does nothing on Debian.

```bash
# run from: the board
cat /proc/version
# Linux version 6.12.0-g70fa2c6d3bdd-dirty (arm-linux-gnueabi-gcc ...)
```

## What is on the SD card

**`firmware/`: one FAT partition, five files.**

| File | What it is |
|---|---|
| `BOOT.bin` | **FSBL + bitstream + U-Boot**, packed by `bootgen` into the one file BootROM expects |
| `uImage` | The Linux kernel |
| `devicetree.dtb` | The description of what hardware exists |
| `uramdisk.image.gz` | The root filesystem (userspace) |
| `uEnv.txt` | U-Boot settings, read at boot |

**`firmware-modern/`: two partitions.** A 128 MB FAT partition with the same files
except `uramdisk.image.gz` (U-Boot boots the second partition instead), and an
ext4 partition holding Debian in the remaining 7.4 GB of an 8 GB card. The running
board mounts the FAT partition at `/boot`, which is where `./devkit flash` writes.

Any FPGA change means replacing `BOOT.bin`: `./devkit flash` over the network if
the board boots, or a card reader if not. **Never use DFU** (updating over USB
from U-Boot) on this board; it cannot replace `BOOT.bin` at all (see
[flashing](flashing.md)). Make a spare card with `./tools/make-sd-card.sh` before
you need one
([Option C2](flashing.md#option-c2--a-second-card-when-you-do-not-want-to-risk-the-first)).

## What to rebuild when you change something

| You changed… | Which file changes | How it gets onto the board |
|---|---|---|
| HDL / block design | `BOOT.bin` (contains the bitstream) | `./devkit flash --target factory --boot-only` (network) or card reader |
| Kernel config or a driver | `uImage` | `./devkit flash --kernel-only`, or card |
| Hardware description | `devicetree.dtb` | `./devkit flash --dtb-only`, or card |
| Boot settings | `uEnv.txt` | `./devkit flash --target factory --all` (factory target) or card |
| Userspace, on `firmware/` | `uramdisk.image.gz` | `./devkit flash --target factory --rootfs-only`, or card |
| Userspace, on `firmware-modern/` | *nothing* | `apt install`, or edit the file in place: it is a real disk |

`build_all.sh`'s seven stages are the chain in dependency order: HDL → bitstream
→ FSBL (which needs the bitstream) → U-Boot → kernel → root filesystem →
package into `BOOT.bin`.

## Watching it happen

On the serial console ([how to connect](flashing.md#verify-your-build-is-actually-running))
every stage announces itself (a 5.15 board shown):

```
U-Boot PlutoSDR (Sep 12 2026 - 15:31:07 +0200)   ← stage 3: FSBL has run,
DRAM:  ECC disabled 1 GiB                           DDR works, U-Boot is alive

reading uImage                                    ← stage 3 loading stage 4
4541632 bytes read in 417 ms
reading devicetree.dtb
22516 bytes read in 18 ms
reading uramdisk.image.gz
6757376 bytes read in 611 ms

## Booting kernel from Legacy Image at 02080000 ...
   Image Name:   Linux-5.15.0                     ← or Linux-6.12.0
Starting kernel ...                               ← handover to Linux

Linux version 5.15.0 ...                          ← stage 4 running
OF: fdt: Machine model: FISH Ball PlutoSDR Rev.A  ← read from the device tree
ad9361 spi0.0: ad9361_probe : AD936x Rev 0        ← Linux finds the radio,
                successfully initialized             because the DTB told it to look

Welcome to Pluto                                  ← stage 6: userspace is up
fishball7020 login:
```

On 6.12 the transmitter-safety patches also log to `dmesg` when they act. These
are the firmware doing its job, and the first place to look when a transmitter
goes quiet:

```
iio iio:device2: no transmit data for 250 ms - muting the transmitter
ad9361 spi0.0: die at 40.351 C is over the 1.000 C transmit limit - staying muted
```
