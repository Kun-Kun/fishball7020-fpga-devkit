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

## The second route in

`usb0` at **192.168.2.1**, a serial console on the same cable, and libiio over USB
— the gadget half of Buildroot's `S23udc`, rebuilt as two units.

This is not a nicety. The first Debian boot came up with `networking.service`
failed, and because this had not been written yet the board was simply
unreachable: **two card-reader trips for what would have been a two-minute fix
over USB.** On the Buildroot rootfs it would have been answering at 192.168.2.1
the whole time.

```
fishball-usb-gadget.service   Before=iiod.service   builds the gadget, mounts functionfs
fishball-usb-bind.service     After=iiod.service    writes the UDC, brings usb0 up
serial-getty@ttyGS0.service                         a console on the same cable
```

Split in two because the factory ordering matters: create the gadget → start
`iiod` on the functionfs → *then* attach to the UDC. Bind before `iiod` is
listening and the host enumerates a device that never answers.

**`After=iiod.service` is not sufficient**, and that cost a boot. A FunctionFS
function is not bindable until its userspace daemon has written descriptors to
`ep0`; until then the UDC write fails with `EIO`:

```
/usr/local/sbin/fishball-usb-bind: 19: echo: echo: I/O error
failed to bind ci_hdrc.0
```

systemd considers a simple service started the moment it has forked, so `iiod` may
not have touched `ep0` yet. Doing it by hand worked only because there were a few
seconds of typing in between — the classic way a race hides. The bind now waits
for `/dev/iio_ffs/ep1` to appear (iiod creates `ep1`–`ep6` once the descriptors
are written) and retries the UDC write.

Verified: after a reboot with no manual steps, the USB route came up in **25 s**,
`UDC` reads `configured`, and both routes serve at once.

| | |
|---|---|
| `ssh root@192.168.2.1` | works |
| `iiod` on `192.168.2.1:30431` | works |
| `./devkit gpio-check` over USB | PASS |
| `./devkit selftest --loopback --pad 20` over USB | 32 passed, 0 failed |
| `/dev/ttyACM0` | answers `fishball login:` — a console on the same cable |

**The two MACs derive from `sha1(hw_serial)` exactly as `S23udc` derives them**,
and that was verified against the original shell byte for byte rather than
reimplemented hopefully. A different derivation renames the interface on your PC
and silently breaks any static address or NetworkManager profile bound to the old
name.

**Your PC's interface is named after `host_addr`, not `dev_addr`** — the address
the gadget hands to the PC end, not the board's own. This page and the script's own
log line both said `dev_addr`, which names an interface that has never existed on
the host and sends you looking for the wrong one. On this board:

| | | |
|---|---|---|
| `host_addr` | `00:E0:22:33:8E:2C` | **your PC's interface: `enx00e022338e2c`** |
| `dev_addr` | `00:05:F7:FE:C6:E0` | the board's own `usb0` |

Both confirmed against the running host, and the name is **stable for a given
board**: `hw_serial` is minted once into `/mnt/jffs2`, which is QSPI rather than
the SD card, so it survives reflashing and the interface keeps its name.

`iiod` gets `-F /dev/iio_ffs` through a **wrapper that checks whether the gadget is
there**, not through `/etc/default/iiod`. Putting it in the environment file would
copy the factory exactly and would also mean any failure to set up the USB gadget
takes IIOD down completely — `iiod` cannot open the endpoint and exits — making
the network daemon every host tool depends on hostage to the fallback route. That
is precisely backwards.

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
  both filesystems are `noatime` with `commit=30`.

  That was `commit=600` and it cost a debugging session. Ten minutes of
  write-back means a hard power cycle silently discards ten minutes of work — it
  discarded a set of units and scripts that had been deployed, verified running
  and `systemctl enable`d, and the filesystem came back **clean** because the
  journal had nothing to replay. The writes had never reached the card. The board
  then booted with no USB gadget and so no way in. `commit=30` bounds the loss to
  something you would notice; the wear difference is negligible next to journald,
  which is capped separately. **`sync` after deploying anything you care about.**
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

And four more from the third boot, three of which are **container-isms leaking into
a real system** and one a consequence of this board having no clock:

| | |
|---|---|
| **ssh died partway through `gpio-check`** | OpenSSH 9.8+ has `PerSourcePenalties` on by default: a source address is penalised for ≥15 s after connections it deems aborted. Our tools open *many* short-lived connections, so a run dies with **"Permission denied, please try again"** and sends you looking at passwords. dropbear had no such mechanism, and every tool here was written against dropbear |
| **PAM refused a correct password** | `account root has password changed in future`. **The board has no RTC** and boots months in the past, while the shadow entry is dated when the image was built. `chage -d 1 root` dates it 1970-01-02 instead |
| **`apt update` failed, circularly** | the same wrong clock makes apt reject Release files as *"not valid yet"* — so you cannot install an NTP client to fix the clock. `systemd-timesyncd` is therefore installed **in the image**, not on the board. Once the clock is right, `apt` fetched 9.5 MB and NTP took over |
| **installed services never started** | the Debian image ships `/usr/sbin/policy-rc.d` returning 101, so `apt install` starts nothing. Harmless during an image build, silently wrong on a real system. It is deleted |

Three lessons, and they are the same lesson three times:

- **Two implementations of a familiar command differ in ways that surface as a
  wrong number, not an error.** `fw_printenv`'s exit status and OpenSSH's
  connection policy both cost a debugging cycle each.
- **A container image is not a root filesystem.** `/etc/hostname` and
  `/etc/hosts` are bind-mounted during `RUN`; `policy-rc.d` exists to stop
  services starting. Both are correct for a build and wrong for a board.
- **Nothing here has a clock.** Anything that compares a timestamp to now —
  PAM, apt, TLS — has to be told, or it will refuse and blame something else.

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


## No baked-in identity, because this tarball is a release asset

Whatever is in `rootfs.tar` is on **every board anyone flashes from it**, so two
things are deliberately absent.

**SSH host keys.** `openssh-server`'s postinst generates them at install time,
which here means inside the build container — so a released tarball would hand
every board in the world the same private host key, downloadable from the
releases page. That makes impersonating any of these boards trivial, and it makes
ssh's key-change warning useless, because the warning would never fire. The
Containerfile deletes `/etc/ssh/ssh_host_*`.

**Machine ID.** `/etc/machine-id` is present and **empty**, which is what tells
systemd this is a first boot. `/var/lib/dbus/machine-id` is a symlink to it
rather than the stale container's copy.

Two units then make new keys on first boot, and it is worth knowing why there are
two:

| | |
|---|---|
| `sshd-keygen.service` | Debian's own, already enabled. Gated on `ConditionFirstBoot`. |
| `fishball-sshd-keygen.service` | ours. Gated on `ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key`. |

`ConditionFirstBoot` is decided by PID 1 during early boot from `/etc/machine-id`
and **cannot be tested from a running system** — emptying the file later does not
flip it, which was checked. A missing host key means no ssh at all on a freshly
written card, and "no way in" is not a failure worth staking on a condition that
cannot be exercised here. So ours keys off the file instead. They are harmless
together: `ssh-keygen -A` only creates keys that are *missing*, so whichever runs
first does the work and the other finds nothing to do.

**Verified on hardware** rather than reasoned about, on 2026-09-27:

| | |
|---|---|
| keys present | `ConditionResult=no` — the unit skips, so it never churns a working board's keys |
| one key type removed | `ssh-keygen -A` recreated exactly that one; 6 files before, 6 after; `sshd -t` OK |
| **all keys removed**, as the release tarball ships | `ConditionResult=yes`, all six regenerated, `sshd -t` OK, `systemctl restart ssh` clean, and a fresh login succeeded |

The board used for that test now carries host keys it generated itself, which is
the intended end state.
