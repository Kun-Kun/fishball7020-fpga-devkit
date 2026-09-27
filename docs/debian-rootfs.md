# Getting off Buildroot

The kernel is done — [`firmware-modern/`](../firmware-modern/README.md) runs Linux
6.12 with the same measured behaviour as the factory 5.15. The **userspace is
where the remaining complaint lives**, and it is the half that
[issue #4](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/4)
was really about: `apt`, a writable root, systemd, and none of busybox's missing
tools.

This page is what the boot path and the running board actually say about doing
that, checked rather than assumed. **Nothing here is built yet.**

## The short version

It is a smaller job than it looks, for four reasons that had to be measured:

| | |
|---|---|
| **U-Boot needs no rebuild.** | `preboot` imports `uEnv.txt` from the card into the U-Boot environment, and `sdboot` is *defined in that file*. The boot command and `bootargs` are editable data. U-Boot 2016.07 never has to be touched — which matters, because the four vendor edits to `include/configs/zynq-common.h` would not port to a modern U-Boot anyway. |
| **U-Boot needs no ext4 support either.** | It loads `uImage` and `devicetree.dtb` from the FAT partition, as now. The *kernel* mounts the ext4 root. |
| **The kernel is nearly ready.** | Of what systemd wants, `EXT4_FS`, `TMPFS` + POSIX ACL, `CGROUPS`, `INOTIFY_USER`, `SIGNALFD`, `TIMERFD`, `EPOLL`, `FHANDLE`, `SECCOMP`, `DEVTMPFS` and `DEVTMPFS_MOUNT` are **already on**. Two are missing: `CONFIG_NAMESPACES` and `CONFIG_AUTOFS_FS`. Two lines in `fishball_defconfig`. |
| **`iiod` can come across unchanged.** | The board's libc is **glibc 2.25, not uClibc** — so its binaries are forward-compatible with a newer glibc — and every library `iiod` needs has the same soname in Debian. |

That last one is the important one, because it removes the only risk that could
have sunk the whole idea.

## Why carrying `iiod` across matters so much

The board's libiio is pinned at **0.25**, and that is not an accident of age.
Cyclic transmit — `OPEN <dev> <n> <mask> CYCLIC` on TCP 30431 — only exists in
libiio's *high-speed* path, which it enables by probing for the legacy
`BLOCK_FREE_IOCTL`. Lose that and `OPEN … CYCLIC` stops working **at the daemon**,
which silently breaks `./devkit gpio-check`, the self-test's loopback tone and
every transmit tool in the MCP server, with nothing in the kernel log to explain
it. It is the same trap that ruled out mainline Linux for this board.

So "just install Debian's `libiio0` and `iiod`" is a decision with teeth, not a
detail. Fortunately it is avoidable. `libiio.so.0.25` is **107 KB**, and this is
everything the two binaries need:

```
libiio.so.0   libpthread.so.0   libc.so.6     librt.so.1    libm.so.6
libdl.so.2    libatomic.so.1    libz.so.1     libxml2.so.2  libaio.so.1
libusb-1.0.so.0   libserialport.so.0   libdbus-1.so.3
libavahi-client.so.3   libavahi-common.so.3
```

Every one of those sonames is shipped by Debian —
`libavahi-client3`, `libavahi-common3`, `libaio1`, `libusb-1.0-0`,
`libserialport0`, `libxml2`, `zlib1g`, `libdbus-1-3`, and the rest is glibc. So
copy `iiod` and `libiio.so.0.25` from the Buildroot build, install those packages,
and the daemon on a Debian root is the **same binary that is known to do cyclic
transmit on this board**. Decide later whether to move to Debian's own packages;
do not make that decision by accident on day one.

## The card

The current card is the constraint. Read off the board:

```
179  0  122880  mmcblk0        120 MB total
179  1  122864  mmcblk0p1      116 MB FAT, 31 MB used, ONE partition
```

A Debian armhf minimal root is roughly 400 MB, and useful with a compiler and
Python is a few GB. So this needs **a bigger card**, and that is also the
migration's safety net: build it on a new card and the current one remains a
complete, bootable rollback that no software of ours can touch.

The layout is forced rather than chosen. The Zynq BootROM reads `BOOT.bin` from a
**FAT** partition, so:

| | | |
|---|---|---|
| `p1` | FAT32, ~100 MB | `BOOT.bin`, `uImage`, `devicetree.dtb`, `uEnv.txt` |
| `p2` | ext4, the rest | the Debian root |

`uramdisk.image.gz` simply stops being loaded. Keeping it on `p1` costs 6.7 MB and
buys a one-line rollback, which is worth it (see below).

## What changes in `uEnv.txt`

Today `sdboot` loads three files and passes the ramdisk to `bootm`:

```
sdboot=if mmcinfo; then run uenvboot; load mmc 0 ${fit_load_address} ${kernel_image} \
  && load mmc 0 ${devicetree_load_address} ${devicetree_image} \
  && load mmc 0 ${ramdisk_load_address} ${ramdisk_image} \
  && bootm ${fit_load_address} ${ramdisk_load_address} ${devicetree_load_address}; fi
```

An ext4 root drops the third load and passes `-` in the ramdisk slot, with
`bootargs` naming the root:

```
bootargs=console=ttyPS0,115200 root=/dev/mmcblk0p2 rootwait rw clk_ignore_unused quiet loglevel=4
sdboot=if mmcinfo; then run uenvboot; load mmc 0 ${fit_load_address} ${kernel_image} \
  && load mmc 0 ${devicetree_load_address} ${devicetree_image} \
  && bootm ${fit_load_address} - ${devicetree_load_address}; fi
```

**`rootwait` is not optional.** The MMC controller probes asynchronously and the
root will not be there yet.

Because both of those are data on the card, **keeping the Buildroot ramdisk as a
selectable fallback costs one `if`** — the same A/B shape as the kernel swap, and
worth having for the first few boots.

## The three init scripts

This is the actual work: ~440 lines of busybox shell that has to become systemd
units, and two of them do things nothing else does.

| script | lines | what it does that matters |
|---|---|---|
| `S21misc` | 94 | **`tx_quiesce`** — sets both transmit attenuators to −89.75 dB at boot, and **`tx_led`** — points the USER LED at the `tx-active` trigger |
| `S23udc` | 201 | mints a persistent **`hw_serial`** into `/mnt/jffs2` on first boot, and writes **`/etc/libiio.ini`** |
| `S40network` | 148 | takes `eth0`'s MAC from the U-Boot environment and sends a DHCP hostname |

Three things there are load-bearing and easy to lose:

- **`tx_quiesce` is a safety mechanism, and its ordering is the mechanism.** The
  device tree covers the moment of probe (`adi,tx-attenuation-mdB = 89750`), and
  the kernel covers any period when a DMA buffer is streaming. `tx_quiesce`
  covers the gap between them. A unit that runs it *after* something can open a
  transmit buffer is decoration. `Before=` whatever starts `iiod`, and no
  `WantedBy=multi-user.target` alone.
- **`/etc/libiio.ini` is read by tools you would not think to check.** It supplies
  `hw_model`, `hw_model_variant`, `fw_version`, `hw_serial` and
  `ad9361-phy,xo_correction` as IIO *context attributes*, and
  `tools/selftest/sdr_selftest.py` and the MCP server both read them. `fw_version`
  comes from the `device-fw` line of `/opt/VERSIONS`, so that file needs an
  equivalent too.
- **`/mnt/jffs2` must be mounted and never reformatted.** `hw_serial` is minted
  there once and seeds the USB gadget's MAC, which fixes the host's `enx<mac>`
  interface name. Lose it and the self-test declares its baseline comparison
  meaningless — correctly, because the board is no longer identifiable as the
  same unit.

## Building the root, without Buildroot

`mmdebstrap` (or `debootstrap --foreign` plus `qemu-arm-static` for the second
stage) produces an armhf root on an x86 host. No cross toolchain, no 25 GB tree,
no 45-minute build — and `apt` works on the board afterwards, which is the entire
point of the exercise.

Rough shape, **untested, written from the boot path rather than from experience**:

```bash
# run from: anywhere, as root, on the HOST
mmdebstrap --architectures=armhf --variant=important \
  --include=systemd-sysv,openssh-server,ifupdown,isc-dhcp-client,libiio0,libavahi-client3,libaio1,libusb-1.0-0,libserialport0 \
  trixie ./rootfs http://deb.debian.org/debian
```

Then copy `iiod` and `libiio.so.0.25` over whatever `libiio0` installed, add the
three units, set a root password, and `tar` it onto `p2`.

## Done is the compatibility contract, not "it boots"

The same bar the kernel work was held to, and for the same reason — every host
tool, the 21-tool MCP server and the three GNU Radio examples sit on top of it:

- `iiod` answering on TCP 30431, **with cyclic transmit working** — check it with
  `./devkit gpio-check`, which fails loudly if cyclic is broken
- the seven transmitter-safety attributes present and behaving
- `/etc/libiio.ini` supplying `hw_model`, `fw_version` and the *same* `hw_serial`
- `ssh` (`tools/flash.sh` and `./devkit selftest --ssh` both need it)
- `./devkit selftest --loopback --pad 20`: **32 passed, 0 failed**, as now
- `./devkit temps`, `./devkit net show`, `./devkit gpio-check` unchanged

And one thing that will change and should be allowed to: `flash.sh` mounts
`/dev/mmcblk0p1` on the running board. That still works — the boot files stay on
a FAT `p1` — but it no longer touches the root filesystem at all, so
`--rootfs-only` becomes meaningless and `./devkit verify --board` will have
nothing to compare for `uramdisk.image.gz`.

## What this does not solve

- **U-Boot is still 2016.07.** Nothing above needs it changed, and that is the
  point; replacing it is a separate job with its own rollback problem, because
  `BOOT.bin` is loaded from a fixed filename by the BootROM and cannot be slot
  switched.
- **The bitstream is untouched**, deliberately. It is a hard invariant across all
  of this work.
- **`main` keeps Buildroot.** The byte-identical factory claim needs the factory
  rootfs, and that claim is the reason `firmware/` exists at all.
