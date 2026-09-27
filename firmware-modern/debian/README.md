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

## Verified on hardware, 2026-09-27

Second boot, after the two first-boot bugs were fixed. Debian 13 trixie, systemd
257, Linux 6.12, root on `/dev/mmcblk0p2`:

| | |
|---|---|
| `./devkit gpio-check` | **PASS** — all four pins, timing error 0.0% / 0.1%. **This is the cyclic-transmit test**, so libiio 0.26 does have the high-speed path, exactly as the `local.c` diff predicted |
| `./devkit selftest --loopback --pad 20` | **32 passed, 1 warning, 0 failed** — the same verdict as Buildroot. TX attenuator 1.007 dB/dB, image rejection 55.3 dBc after calibration, 2nd harmonic −64.4 dBc, +19.0 dBm flat out, all inside the documented spread |
| receive throughput | **220.0 / 430.8 MB/s** (1 and 2 channels, 134.4 Msample runs) — *identical to Buildroot to the digit* |
| transmit under load | a fed 117 MB/s stream ran 10 s with the underflow counter **flat at 10** after start-up. systemd costs the DAC nothing in steady state |
| `patches/0015` starvation mute | **0.26 s**, against 0.27 s on Buildroot and on 5.15 |
| `hw_serial` | `b8f4c99de8525565d3f4fe3c917ad834` — **the same as the Buildroot system**, read from `/mnt/jffs2` |
| `/etc/libiio.ini` context attributes | `hw_model`, `hw_model_variant`, `hw_serial`, `fw_version=debian-13`, `xo_correction` all served |
| `./devkit temps`, `./devkit net show` | unchanged |
| `fishball.local` | resolves, via avahi |
| failed units | **0**, `systemctl is-system-running` = `running` |

The one selftest warning is `patches/0015` doing its job: the selftest set
61.75 dB, its stream starved, and the driver muted underneath it. Buildroot
produces the same warning.

## What the first two boots cost, and what they taught

Four bugs, all mine, none in Debian or the kernel. Recording them because three
were invisible until something was read back rather than assumed.

| | |
|---|---|
| **the safety unit was deleted** | `Before=sysinit.target` *and* `WantedBy=sysinit.target` is a cycle; systemd broke it by dropping the job. Nothing radiated — the device tree still covered probe — but the layer was absent and only the journal knew |
| **the interface was `end0`** | systemd-udevd renames `eth0`; Buildroot's mdev did not. `networking.service` failed and the board had no route in at all. Fixed with `net.ifnames=0` |
| **the hostname was `debuerreotype`** | podman **bind-mounts** `/etc/hostname` and `/etc/hosts` during `RUN`, so `echo fishball > /etc/hostname` never reached the image layer. avahi published the wrong name. They live in `overlay/` now, because `COPY` does reach the layer |
| **the DMA ceiling was 16 MB, not 64** | libubootenv's `fw_printenv` exits **0 with empty output** for an unset variable, unlike Buildroot's, so `|| echo 67108864` never fired and an empty string was written. Host streaming throughput is a function of buffer size, so this quietly capped it |

The lesson the second and fourth share: **two implementations of the same command
differ in ways that only show up as a wrong number.** Neither failed loudly.

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
