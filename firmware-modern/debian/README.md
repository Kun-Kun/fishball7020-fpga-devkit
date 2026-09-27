# The Debian armhf root for this board

Replaces Buildroot and busybox with **Debian 13 (trixie) armhf**, systemd and
`apt`, on an SD card partition instead of a RAM disk. The kernel, bitstream,
U-Boot and `BOOT.bin` are unchanged — this is only the userspace.

Why, and what the boot path allows: [`docs/debian-rootfs.md`](../../docs/debian-rootfs.md).

```bash
# run from: firmware-modern/debian/
./build.sh                       # -> rootfs.tar   (slow: emulated armhf)
sudo ./write-card.sh /dev/sdX    # refuses anything not removable
```

| | |
|---|---|
| `Containerfile` | what the root filesystem *is*, with the reasoning for each unobvious package |
| `build.sh` | builds it and exports `rootfs.tar`. Touches no card, deliberately |
| `write-card.sh` | partitions and writes a card. Refuses non-removable devices |
| `make-uenv.sh` | generates a `uEnv.txt` that can boot **either** root |
| `overlay/` | our units, `fstab`, network, journald and sshd configuration |

## It is built in a container, not with debootstrap

`mmdebstrap` needs Debian's archive keyring to verify trixie, and Ubuntu 22.04's
`debian-archive-keyring` stops at **bullseye** — it fails with
`NO_PUBKEY 6ED0E7B82643E131` and the only fixes involve hand-trusting a
downloaded keyring. An official signed `arm32v7/debian:trixie` image avoids the
question, and `apt` inside it is native armhf under `qemu-user`.

Host requirements:

```bash
sudo apt install podman qemu-user-static binfmt-support arch-test
arch-test armhf        # must print "armhf: ok"
```

## Two units, and why they are two

```
fishball-rf-quiesce.service    Before=iiod.service, WantedBy=sysinit.target
fishball-identity.service      After=rf-quiesce, Before=iiod.service
```

`S21misc` did both jobs plus copied ssh keys, in one script. Splitting them is
the point: **`fishball-rf-quiesce` does exactly one thing and is ordered before
anything that can open a transmit buffer.** That ordering *is* the safety
mechanism. It is the middle of three layers:

| | |
|---|---|
| the device tree | `adi,tx-attenuation-mdB = 89750` — covers the instant `ad9361_setup()` runs, before any userspace exists |
| **this unit** | covers from then until a DMA buffer starts |
| the kernel | `patches/0004` mutes when a transmit buffer stops, `0015` when the DAC starves |

It waits (bounded, 10 s) for `ad9361-phy` to appear, writes −89.75 dB to both
attenuators, and then **reads them back** — because the point is to know, not to
have executed a line. It logs to the console as well as the journal, and fails
noisily rather than quietly, but it does not stop the boot: a board you cannot
reach is worse than one whose transmitter needs checking.

`fishball-identity` mints `hw_serial` into `/mnt/jffs2` once and writes
`/etc/libiio.ini`. Both are read by things that do not look like they would:
`tools/selftest/sdr_selftest.py` and the MCP server take `hw_model`, `hw_serial`
and `fw_version` from the IIO *context* attributes that file supplies, and a board
whose serial changes looks like a different unit to everything that keeps a
baseline.

## What the card ends up as

```
p1  128 MB  FAT32  BOOT.bin  uImage  devicetree.dtb  uEnv.txt
                   uramdisk.image.gz          <- the fallback, 6.8 MB
p2  the rest ext4  the Debian root
```

`p1` must be FAT because the Zynq BootROM reads `BOOT.bin` from it. The ramdisk
stays because it makes the old userspace one variable away:

```bash
fw_setenv rootfs_mode ramdisk     # boot Buildroot next time
fw_setenv rootfs_mode debian      # or unset it - Debian is the default
```

`rootfs_mode` is deliberately **not** defined in `uEnv.txt`, only tested. U-Boot
imports `uEnv.txt` over its saved environment on every SD boot, so defining it
there would make `fw_setenv` appear to work and then be silently overridden —
the worst kind of switch. The ramdisk path also does not set `bootargs`, so the
fallback stays bit-for-bit the boot that works today.

## Two costs, stated up front

- **SD card writes.** The rootfs it replaces was a RAM disk that wrote to the
  card *never*. journald is bounded to 32 MB with a 10-minute sync interval, and
  both filesystems are `noatime` with `commit=600`, but this is a real change in
  kind and not just degree.
- **`apt` is slow.** Dual Cortex-A9 at 333 BogoMIPS. `dpkg` unpacking is minutes.

## Done is the compatibility contract, not "it boots"

Every host tool, the 21-tool MCP server and the three GNU Radio examples sit on
this, so:

- `iiod` on TCP 30431 **with cyclic transmit working** — `./devkit gpio-check` is
  the test, and it fails loudly if cyclic is broken
- the seven transmitter-safety attributes present and behaving
- `/etc/libiio.ini` serving `hw_model`, `fw_version` and the **same** `hw_serial`
- `ssh` as root with a password, because `tools/flash.sh` and
  `./devkit selftest --ssh` use it
- `./devkit selftest --loopback --pad 20`: 32 passed, 0 failed
- `./devkit temps`, `./devkit net show`, `./devkit gpio-check` unchanged

And one worth measuring rather than assuming, because transmit is the
latency-critical path and systemd is more userspace than busybox was:
**`tx_dma_underflow_count` during a cyclic transmit.** If Debian costs underflows,
`chrt` on `iiod` is the answer — but find out first.
