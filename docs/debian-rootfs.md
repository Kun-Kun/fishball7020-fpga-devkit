# Why the modern target runs Debian

The factory firmware runs Buildroot and busybox from a RAM disk: no `apt`,
nothing survives a reboot, and many familiar tools are missing or cut down.
[Issue #4](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/4)
asked for a real distribution. The modern target's root filesystem is
**Debian 13 (trixie) armhf with systemd**, on an ext4 partition of the SD card.

This page is the design: what the boot path allows, what had to be kept
compatible, and what was left alone.
[`firmware-modern/debian/README.md`](../firmware-modern/debian/README.md) is the
quick start, and [`debian-root-reference.md`](debian-root-reference.md) explains
each unit and setting in the image.

## What the boot path allows

| | |
|---|---|
| **U-Boot does not need rebuilding.** | `preboot` imports `uEnv.txt` from the card into U-Boot's environment, and the boot command `sdboot` is defined in that file. So the boot command and the kernel command line are data on the card. |
| **U-Boot does not need ext4 support.** | It loads `uImage` and `devicetree.dtb` from the FAT partition as before. The kernel mounts the ext4 root. |
| **The kernel needs two more options.** | systemd's other requirements (`EXT4_FS`, `TMPFS` with POSIX ACLs, `CGROUPS`, `INOTIFY_USER`, `SIGNALFD`, `TIMERFD`, `EPOLL`, `FHANDLE`, `SECCOMP`, `DEVTMPFS`, `DEVTMPFS_MOUNT`) are already on. `CONFIG_NAMESPACES` and `CONFIG_AUTOFS_FS` are added in `fishball_defconfig`. |
| **Debian's own `iiod` works.** | See the next section. |

## Why Debian's `iiod` is safe to use

`iiod` is the libiio server every host tool talks to. **Cyclic transmit**
(`OPEN <dev> <n> <mask> CYCLIC` on TCP 30431, the board repeating one buffer
in hardware) exists only in libiio's high-speed path, which libiio enables by
probing for `BLOCK_FREE_IOCTL`. An `iiod` without it breaks `./devkit gpio-check`,
the self-test's loopback tone and the MCP server's transmit tools, and nothing
in the kernel log says why.

The factory board runs libiio 0.25 (commit `38483f31`). Debian trixie ships
**0.26**, the last of the 0.x line; the block interface changed only in 1.0.
Between the two, `local.c`, which holds the high-speed probe and the cyclic
code, is unchanged:

```
$ git diff --stat 38483f31 v0.26
 CI/azure/prepare_assets.sh     |  2 +-
 CI/publish_deps.ps1            | 10 +++++-----
 CMakeLists.txt                 |  2 +-
 azure-pipelines.yml            | 14 ++++++--------
 iiod/CMakeLists.txt            |  5 +++++
 iiod/init/iiod.service.cmakein |  5 +++--
 serial.c                       |  5 +++++
 xml.c                          |  1 +
 8 files changed, 27 insertions(+), 17 deletions(-)

$ git diff --quiet 38483f31 v0.26 -- local.c && echo identical
identical
```

So the image installs Debian's `iiod` package, and an apt pin
(`overlay/etc/apt/preferences.d/fishball-libiio.pref`) holds it at that version.

**Copying the factory `iiod` binary across does not work.** It needs
`libaio.so.1`, and trixie has only `libaio.so.1t64`, from Debian's 64-bit
`time_t` transition. The rename matters here: `io_getevents()` takes a
`struct timespec *`, so `time_t` is part of the library's interface, and a
symlink would hand a 32-bit-`time_t` caller a library that expects 64 bits.

## The card

The Zynq's boot ROM reads `BOOT.bin` from a **FAT** partition, so:

| | | |
|---|---|---|
| `p1` | FAT32, 128 MB | `BOOT.bin`, `uImage`, `devicetree.dtb`, `uEnv.txt`, and the Buildroot ramdisk if a factory build is available |
| `p2` | ext4, the rest | the Debian root |

A minimal Debian root is about 300 MB, and with a compiler and Python a few
GB, so it needs a bigger card than the factory one. Building on a new card
also keeps the old card as a complete rollback.

## What changes in `uEnv.txt`

The factory `sdboot` loads the kernel, the device tree and the ramdisk:

```
sdboot=if mmcinfo; then run uenvboot; load mmc 0 ${fit_load_address} ${kernel_image} \
  && load mmc 0 ${devicetree_load_address} ${devicetree_image} \
  && load mmc 0 ${ramdisk_load_address} ${ramdisk_image} \
  && bootm ${fit_load_address} ${ramdisk_load_address} ${devicetree_load_address}; fi
```

An ext4 root drops the ramdisk load, passes `-` in its place, and names the
root on the kernel command line:

```
bootargs=console=ttyPS0,115200 root=/dev/mmcblk0p2 rootwait rw clk_ignore_unused net.ifnames=0
sdboot=if mmcinfo; then run uenvboot; load mmc 0 ${fit_load_address} ${kernel_image} \
  && load mmc 0 ${devicetree_load_address} ${devicetree_image} \
  && bootm ${fit_load_address} - ${devicetree_load_address}; fi
```

**`rootwait` is required**: the SD controller probes asynchronously, and the
root is not there yet when the kernel first looks. `firmware-modern/debian/make-uenv.sh`
generates the real file, which can boot either root, chosen by `rootfs_mode`.

## The factory init scripts, and what replaced them

Three busybox scripts do the board-specific work on the factory firmware:

| factory script | what it does | on Debian |
|---|---|---|
| `S21misc` | sets both transmitters to −89.75 dB at boot; points the USER LED at the `tx-active` trigger | `fishball-rf-quiesce`, and `fishball-identity` for the LED |
| `S23udc` | mints the persistent `hw_serial` into `/mnt/jffs2`; writes `/etc/libiio.ini`; sets up the USB gadget | `fishball-identity`, `fishball-usb-gadget`, `fishball-usb-bind` |
| `S40network` | takes `eth0`'s MAC from U-Boot's environment; sends a DHCP hostname | `overlay/etc/network/interfaces` |

Three things in them must not be lost:

- **The boot-time transmitter mute is a safety mechanism, and its ordering is
  what makes it work.** It must run before anything can open a transmit buffer.
- **`/etc/libiio.ini` is read by tools you would not think to check**: the
  self-test and the MCP server take `hw_model`, `hw_serial` and `fw_version`
  from it.
- **`/mnt/jffs2` is never reformatted.** `hw_serial` lives there, and it fixes
  the USB interface name on your PC and the board's identity in every stored
  baseline.

[`debian-root-reference.md`](debian-root-reference.md) describes each
replacement unit.

## Building the root

The root is built **inside Debian's official `arm32v7/debian:trixie` container
image**, not with `mmdebstrap`. `mmdebstrap` needs Debian's archive keyring to
verify trixie, and Ubuntu 22.04's `debian-archive-keyring` stops at bullseye:
it fails with `NO_PUBKEY 6ED0E7B82643E131`, and the only fix is trusting a
downloaded keyring by hand. The signed registry image avoids that, and `apt`
inside it runs as native armhf under `qemu-user` emulation.

```bash
# run from: the repo root
./devkit build --target modern --rootfs-only        # -> firmware-modern/debian/rootfs.tar
sudo ./devkit write-card --target modern /dev/sdX   # refuses anything not removable
```

Rebuild the root whenever `firmware-modern/debian/overlay/` changes. `rootfs.tar`
is a build output and `overlay/` is its source; `write-card` refuses a tarball
older than the overlay and lists the files it would miss.

Every package, and the reason for each unobvious one, is in
[`packages.txt`](../firmware-modern/debian/packages.txt). One example of why that
file exists: `fw_printenv` and `fw_setenv` come from `libubootenv-tool`, not
`u-boot-tools`, on a current Debian, and without them the board cannot read its
MAC address from U-Boot and picks a random one every boot.

## The compatibility contract

"It boots" is not the bar. Every host tool, the MCP server and the GNU Radio
examples depend on:

- `iiod` answering on TCP 30431, **with cyclic transmit working**. Check it
  with `./devkit gpio-check`, which fails loudly if cyclic is broken.
- the seven transmitter-safety attributes present and behaving
- `/etc/libiio.ini` supplying `hw_model`, `fw_version` and the *same* `hw_serial`
- `ssh` as root, which `tools/flash.sh` and `./devkit selftest --ssh` use
- `./devkit selftest --loopback --pad 20` passing, as on the factory firmware
- `./devkit temps`, `./devkit net show` and `./devkit gpio-check` unchanged

`tools/flash.sh` still works: it mounts the FAT `p1` on the running board. It
never touches the root filesystem, so `flash --rootfs-only` does not apply to
this target.

## What this does not change

- **U-Boot is still 2016.07.** Nothing here needs a newer one. Replacing it is
  a separate job with its own rollback problem: the boot ROM loads `BOOT.bin`
  by a fixed name, so there is no A/B slot to fall back to.
- **The bitstream is unchanged.** Both targets boot the same FPGA design.
- **The factory target keeps Buildroot.** Its byte-identical factory claim needs
  the factory root filesystem.
