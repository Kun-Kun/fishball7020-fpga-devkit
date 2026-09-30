# The Debian root filesystem

The modern target's userspace: **Debian 13 (trixie) armhf** with systemd and
`apt`, on the SD card's second partition. It replaces the factory target's
Buildroot and busybox, which ran from RAM. The boot files (`BOOT.bin`, the
kernel, the device tree) come from `./devkit build --target modern`; this
directory is only the root filesystem, and the tool that writes a card.

## Quick start

```bash
# run from: the repo root
./devkit build --target modern --rootfs-only              # -> rootfs.tar (~10 min, emulated ARM)
./devkit write-card --target modern --dry-run /dev/sdX    # checks the device, writes nothing
sudo ./devkit write-card --target modern /dev/sdX         # erases and writes the card
```

`write-card` refuses any disk that is not removable, shows you what it is about
to erase, and makes you confirm. Other ways to use it:

```bash
# run from: the repo root
sudo ./devkit write-card --target modern --image card.img                   # a new image file instead of a card
sudo ./devkit write-card --target modern --from "$HOME/Downloads" /dev/sdX  # the files of a downloaded release
```

**What the build needs on your PC:** podman or docker, and ARM emulation
(`qemu-user` registered with the kernel, so ARM programs run on an x86 PC). If
the emulation is missing, the build sets it up itself, which needs docker or
`sudo podman`. With rootless podman, install it from your distro:

```bash
# run from: anywhere
sudo apt install podman qemu-user-static binfmt-support         # Debian/Ubuntu
sudo pacman -S podman qemu-user-static qemu-user-static-binfmt  # Arch
```

## Getting in

| | |
|---|---|
| over Ethernet | `ssh root@fishball.local`, libiio at `ip:fishball.local` |
| over the USB cable | `ssh root@192.168.2.1`, libiio at `ip:192.168.2.1` |
| serial console | on the same USB cable: `/dev/ttyACM0` on your PC |

The USB link comes up even when Ethernet does not, so keep the cable connected
while you change things.

## What the card looks like

```
p1  128 MB  FAT32  BOOT.bin  uImage  devicetree.dtb  uEnv.txt
p2  the rest  ext4   the Debian root
```

`p1` must be FAT, because the Zynq's boot ROM reads `BOOT.bin` from it.

If you have a factory build (`firmware/output/uramdisk.image.gz`), `write-card`
also puts its Buildroot ramdisk on `p1`, and you can switch between the two
roots from the board:

```bash
# run from: the board
fw_setenv rootfs_mode ramdisk     # boot Buildroot next time
fw_setenv rootfs_mode debian      # back to Debian (or unset it; Debian is the default)
```

Without a ramdisk on the card, leave `rootfs_mode` unset.

## What is in this directory

| | |
|---|---|
| `packages.txt` | what is installed, and why each unobvious package is there. Also shipped on the board at `/usr/share/fishball/packages.txt` |
| `Containerfile` | turns Debian's official `arm32v7/debian:trixie` image into a root filesystem. The image is pinned by digest and the packages come from a fixed snapshot.debian.org date, so rebuilding the same commit installs the same thing |
| `build.sh` | builds the image and exports `rootfs.tar`. Never touches a card |
| `check-rootfs.sh` | checks a built `rootfs.tar`: no keys or IDs baked in, the safety units in place, the pinned image and snapshot recorded. CI runs it too |
| `write-card.sh` | partitions and writes a card, or an image file |
| `make-uenv.sh` | generates the `uEnv.txt` that boots Debian or the ramdisk |
| `overlay/` | the files copied over Debian: the board's systemd units and scripts, and its network, ssh, journald and fstab settings |

**Rebuild `rootfs.tar` after changing anything in `overlay/`.** Nothing
rebuilds it for you, and `write-card` refuses a tarball older than the overlay.
`OVERLAY_OK=1` overrides that; don't use it for a card that will transmit, since
the overlay holds the transmitter's safety settings.

## What runs at boot

| unit | does |
|---|---|
| `fishball-rf-quiesce` | sets both transmitters to maximum attenuation, checks it, and bounds unattended transmits to 60 s. `iiod` does not start if this fails |
| `fishball-identity` | the board's serial number and `/etc/libiio.ini` |
| `iiod` | the libiio server every host tool talks to |
| `fishball-usb-gadget`, `fishball-usb-bind` | the USB network link, console and libiio |
| `fishball-sshd-keygen` | the ssh host keys, on first boot |

[`docs/debian-root-reference.md`](../../docs/debian-root-reference.md) explains
each one, and the settings in `overlay/`.

To see what is installed on a board, and which build it is:

```bash
# run from: the board
cat /opt/VERSIONS                        # the build, and every package at its exact version
cat /usr/share/fishball/packages.txt     # what was asked for, and why
```

## Known problem: unplugging the USB cable loses 192.168.2.1

After you unplug and replug the USB cable, `192.168.2.1` stops answering. The
board is still running: `lsusb` shows `0456:b673 PlutoSDR` and your PC's `enx…`
interface is back. The board's `usb0` has lost its address, because
`fishball-usb-bind` runs once at boot and nothing re-runs it on replug.

Power-cycle the board, or, if you can reach it over Ethernet:

```bash
# run from: the board
systemctl restart fishball-usb-bind
```

To tell this apart from a board that has crashed:

| check, on your PC | means |
|---|---|
| `lsusb \| grep 0456:b673` shows the board | Linux is running on it |
| `cat /sys/class/net/enx…/carrier` reads `1` | the USB link is up |
| `ip neigh show dev enx…` says `FAILED` | the board has no address on `usb0`: this problem |

## Further reading

- [`docs/debian-root-reference.md`](../../docs/debian-root-reference.md): the
  boot units, transmitter safety, the USB route, and how this root differs from
  Buildroot and from a container image.
- [`docs/debian-rootfs.md`](../../docs/debian-rootfs.md): why the board moved
  off Buildroot, and the compatibility it had to keep.
