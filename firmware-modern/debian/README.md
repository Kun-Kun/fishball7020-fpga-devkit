# The Debian armhf root for this board

Replaces Buildroot and busybox with **Debian 13 (trixie) armhf**, systemd and
`apt`, on an SD card partition instead of a RAM disk. `BOOT.bin` (FSBL,
bitstream, U-Boot) is built by `./devkit build --target modern` from the XSA you
give it, with the factory target's FSBL and U-Boot sources — this directory is only
the userspace.

Why, and what the boot path allows: [`docs/debian-rootfs.md`](../../docs/debian-rootfs.md).

```bash
# run from: firmware-modern/debian/
./build.sh                       # -> rootfs.tar   (slow: emulated armhf)

# run from: the repo root
./devkit write-card --target modern --dry-run /dev/sdX   # the device checks, nothing written
sudo ./devkit write-card --target modern /dev/sdX        # refuses anything not removable
sudo ./devkit write-card --target modern --image card.img # a NEW image file, for testing
```

**Rebuild `rootfs.tar` whenever `overlay/` changes.** `write-card.sh` refuses to
write a tarball older than the overlay, and on 2026-09-30 it did exactly that:
the tarball predated the `fishball-rf-quiesce` change that bounds unattended
cyclic transmits at 60 s, so a card written from it would have lost that. Reading
the image back confirmed it — no `tx_cyclic_bound` in its quiesce script.
`OVERLAY_OK=1` overrides it; do not, for a card that will transmit.

The card's `BOOT.bin` and `uEnv.txt` come from the modern build
(`./devkit build --target modern`) when it has made them, and its bitstream is
compared with **the card being overwritten** before anything is written, so an
FPGA change is never silent.

| | |
|---|---|
| `packages.txt` | **what is installed, and why each unobvious one is there** — the build input *and* the manifest, shipped on the board at `/usr/share/fishball/packages.txt` |
| `Containerfile` | how a container image is turned into a real root: units enabled, identity stripped, `/opt/VERSIONS` written |
| `build.sh` | builds it and exports `rootfs.tar`. Touches no card, deliberately |
| `write-card.sh` | partitions and writes a card. Refuses non-removable devices. `--dry-run`, and `--image` for a new image file |
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
fishball-rf-quiesce.service    After=sysinit.target, Before=iiod.service, WantedBy=multi-user.target
fishball-identity.service      After=rf-quiesce, Before=iiod.service
iiod.service (drop-in)         Requires=fishball-rf-quiesce.service   <- fail closed
```

**iiod does not start unless the quiesce succeeded** (since 2026-09-30). iiod is
the one process that opens a transmit buffer without being asked, so if the
attenuators did not read back at −89.75 dB — or the cyclic bound did not take —
there is no network SDR service at all. The board stays reachable:
`fishball-usb-bind` sees that iiod is not serving its USB function and binds the
gadget without it, so `usb0` and the USB console come up and
`journalctl -b -u fishball-rf-quiesce -u iiod` says why. Tested on the board with a
forced quiesce failure: iiod *"Dependency failed"*, `usb0` and the console up, both
attenuators at −89.75 dB. A kernel without `tx_cyclic_timeout_ms` is warned about,
not failed.

`S21misc` did both jobs plus copied ssh keys, in one script. Splitting them is
the point: **`fishball-rf-quiesce` does exactly one thing and is ordered before
anything that can open a transmit buffer.** That ordering *is* the safety
mechanism. It is the middle of three layers:

| | |
|---|---|
| the device tree | `adi,tx-attenuation-mdB = 89750` — applied at `ad9361.c:5326`, near the **end** of `ad9361_setup()`. The TX quadrature calibration at `:5308` runs first and transmits, so a few ms escape at every power-on on both ports ([`IDLE-CASES.md`](../../IDLE-CASES.md)) |
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
| `/etc/libiio.ini` context attributes | `hw_model`, `hw_model_variant`, `hw_serial`, `fw_version` (the release, e.g. `v2.0`), `fw_build` (the full `git describe`, since `/opt/VERSIONS` exists — `fw_version` read `debian-13` before), `xo_correction` all served |
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


## What is installed, and how you find out on the board

`packages.txt` is the build input — the Containerfile greps the comments out and
hands the rest to `apt` — and it is **also copied into the image** and left at
`/usr/share/fishball/packages.txt`. That is deliberate: before this, the only
statement of what a board was running lived in nine continuation lines of a
Containerfile that never leaves the build host, and a released `rootfs.tar` came
with a checksum and no description of its contents.

It records **intent**. `/opt/VERSIONS` records **fact**:

```
device-fw v2.0-9-g5ae29d94-dirty
debian 13 armhf
built 2026-09-27T18:46:34Z
#
# every installed package, from dpkg-query -W:
adduser 3.152
apt 3.0.3
...
```

29 packages requested, **193 installed** once dependencies are resolved — which is
why the resolved list is worth having and the requested list is not enough. The
`device-fw` line comes from a `git describe` that `build.sh` passes in as a build
argument, because the container cannot reach the host's git.

**It also fixes something that had been wrong since this rootfs existed.**
`fishball-identity` reads that line to populate `fw_version` in
`/etc/libiio.ini`, which `tools/selftest/sdr_selftest.py` and the MCP server both
read. With no `/opt/VERSIONS` it always took its fallback, so every board reported
`fw_version=debian-13` — true, and useless for telling two builds apart.
`docs/debian-rootfs.md` had this written down as an unmet requirement. Measured on
the board before and after:

```
before:  fw_version=debian-13
after:   fw_version=v2.0
         fw_build=v2.0-9-g5ae29d94-dirty
```

**Why two attributes rather than one.** `fw_version` carries the release and
`fw_build` the full `git describe`, because MATLAB's ADALM-Pluto support package
cannot cope with a describe string in `fw_version` and fails *closed*: it tries
to raise `plutoradio:sysobj:FirmwareIncompatible`, a message its own catalogue
declares `context="warning"` and whose text reads *"You can continue using
version {1}"* — but it supplies the wrong type for one of that message's five
parameters, so **building the warning throws** and the throw aborts the
connection. Measured by editing `/etc/libiio.ini` on a running board and
restarting `iiod` between each: `v2.0`, `2.0`, `v2.0.1` and `v2.0-dirty` connect;
`v2.0-9-g5ae29d94-dirty`, `v2.0-9-g5ae29d94` and `v2.0-9-gabcdef` do not. It is
the describe *shape*, not the version number.

Nothing here parses `fw_version` — the self-test and the MCP only display it —
and upstream Pluto firmware reports a clean `v0.38`, so this is a return to the
convention rather than a deviation. See [`docs/matlab.md`](../../docs/matlab.md).

**What is deliberately *not* pinned, and you should know it.**
`Containerfile`'s `FROM` is a floating `arm32v7/debian:trixie` with no digest, and
no package is version-pinned. Two builds a month apart will differ. `/opt/VERSIONS`
does not prevent that — it makes it *visible*, which is the cheaper half of the
problem and the one worth solving first.

## Why those shutdowns stalled: a restart loop that systemd could not rate-limit

The section below bounds the damage. This is the cause, found on 2026-09-28.

`systemd-logind` can enter a state where it **spins** at startup: it burns about
26 s of CPU, never sends `READY=1` (the unit is `Type=notify-reload`), hits its
90 s start timeout and is SIGKILLed. It never logs a line of its own, so it is
spinning before it gets that far. From the previous boot's journal:

```
systemd-logind.service: start operation timed out. Terminating.
systemd-logind.service: Consumed 26.407s CPU time.
systemd-logind.service: Scheduled restart job, restart counter is at 7.
```

**Why it never stopped by itself is the part worth knowing.** The upstream unit
is `Restart=always` with `RestartSec=0`, and systemd's default loop protection
is five starts within ten seconds. Each failure here takes *ninety* seconds, so
the burst counter has long expired before the next attempt and the rate limiter
**never trips**. A failure slow enough defeats the protection designed to catch
exactly this.

What that costs on a 666 MHz dual-core: a permanent CPU load plus an endless
stream of jobs through PID 1. The symptoms all follow from there, and every one
of them was measured:

| symptom | why |
|---|---|
| `systemctl` blocks, while `ps` shows PID 1 idle in `do_epoll_wait` | PID 1 is saturated, not blocked |
| plain ssh stays instant in the same session | nothing is wrong with the board |
| `systemd-random-seed`'s ExecStop takes 20 min | it is **0.051 s** run by hand; the job is queued behind the loop |
| `systemd-shutdown` never runs, the SoC never resets | the transaction never completes |
| the board looks dead and gets its power pulled | which risks the next boot starting the same way |

The fix is `etc/systemd/system/systemd-logind.service.d/fishball.conf`: a start
limit with a window *longer than the failure*, so the limiter works as intended.

**Verified on hardware.** Killing logind repeatedly: it restarted after kills
1-3 and went `failed` on the 4th - `Start request repeated too quickly` - and
stopped. With logind failed the board is entirely healthy: `systemctl` answers
in 3 s, `list-jobs` reports none, ssh works (nothing here needs `pam_systemd`),
and a reboot completed in **under 30 s with zero stalled stop jobs**. Afterwards
`systemctl start systemd-logind` succeeds in 0.6 s, so the guard does not break
a healthy logind.

**logind is now masked**, because after five hypotheses tested and rejected the
honest move was to remove the failure class rather than keep bounding it. It is
unused on this board, and that was checked rather than assumed:

- only `multi-user.target` wants it, a soft dependency
- `pam_systemd` appears **only** in `/etc/pam.d/runuser-l`, as `-session
  optional` - not in `sshd` or `login`, so no login path touches it
- `loginctl list-sessions` reports **no sessions**; the single `seat0` is the
  one logind creates for itself

and the board was already observed fully healthy for an extended period with
logind in the `failed` state. Verified after masking: boot **13.8 s** (the
fastest measured, down from 14.45), **0 failed units**, iiod and the USB gadget
up, ssh fine, and a serial console login fine (`SERIAL LOGIN OK as root, tty
/dev/ttyPS0`). One symlink, reversible with `systemctl unmask systemd-logind`.

The start-limit drop-in is deliberately kept alongside: it is inert while the
unit is masked, and it is what protects anyone who unmasks it.

**A second, independent finding: the journal was two-thirds dead weight.**
`SystemMaxUse=32M` with `SystemMaxFileSize=8M` means only four files fit, and
two of the four were corrupt archives left by unclean shutdowns:

```
27.1M of 32M used
  system.journal          8 MB  (active)
  system@....journal~     8 MB  <- corrupt
  system@....journal~     8 MB  <- corrupt
  system@....journal      8 MB
```

journald was rotating and compressing against an almost-full store, on a
666 MHz core, and `journalctl` stops reading at the first corruption - which is
why reading back what happened kept finding nothing. Deleting the two `~` files
took it to **11.1M**. Worth checking after any run of unclean shutdowns:

```bash
# run from: the board
journalctl --disk-usage
rm -f /var/log/journal/*/system@*.journal~   # corrupt archives; journalctl cannot read them anyway
```

**Why logind spins is still not known**, and the following were tested and
ruled out rather than assumed. It happened once in roughly fifteen boots and has
not been reproducible since, so this is an open question, not a solved one.

| hypothesis | how it was tested | result |
|---|---|---|
| `ttyGS0` vanishing with the USB gadget makes logind spin on a dead fd | bounced the gadget three times via `systemctl restart iiod`, then restarted logind | **rejected** - logind restarted in 0.8 s, stayed active |
| logind races dbus and spins when the bus is not ready | compared `Starting`/`Started` ordering across four boots | **rejected** - the order is identical in every boot (`Starting dbus`, `Starting logind`, `Started dbus`, `Started logind`); healthy boots complete logind in ~1 s |
| an unclean shutdown leaves state that breaks it | boot -1 also logged `EXT4-fs: recovery complete` | **rejected** - logind was healthy on that boot |

What IS known: on the failing boot logind failed on its **first** attempt, ~95 s
after boot, and never logged a line of its own - not even `New seat seat0`,
which a healthy start prints. So it hangs very early, before it can say
anything, and it burns CPU rather than blocking. It is a known class of problem
upstream ([Debian #840475](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=840475),
[systemd #16051](https://github.com/systemd/systemd/issues/16051)) without a
cause that matches this board.

**If it recurs, this is how to find out.** The guard leaves the unit `failed`
instead of looping, so the board stays usable and there is time to look:

```bash
# run from: the board, once logind has failed
mkdir -p /run/systemd/system/systemd-logind.service.d
printf '[Service]\nEnvironment=SYSTEMD_LOG_LEVEL=debug\n' \
  > /run/systemd/system/systemd-logind.service.d/debug.conf
systemctl daemon-reload && systemctl reset-failed systemd-logind
systemctl start systemd-logind        # then read: journalctl -u systemd-logind
```

`/run` rather than `/etc` on purpose: it is gone at the next boot, so turning
this on to catch one occurrence cannot become a permanent property of the
image.

## Fixed: a reboot took twenty-nine minutes and then did not reboot

This is the "the board has hung" that runs through this project's history. It
was never a hang. Caught on the serial console, a single reboot spent:

| stop job | ran for | its own TimeoutStopSec |
|---|---|---|
| `systemd-random-seed` | 20 min | 10 min |
| `networking` | 9 min 17 s | 1 min 30 s |
| `systemd-user-sessions` | 3 min 17 s | 1 min 30 s |
| `systemd-tmpfiles-clean` | 1 min 30 s | 1 min 30 s |

and then the console went silent after `reboot.target`. `systemd-shutdown`
never printed `Unmounting file systems`, the SoC never reset, and the board sat
dead until the power was pulled. Each of those power cuts is also what corrupts
the journal - `journalctl --verify` reports "Bad message" at 4% of an 8 MB file
- which is why every attempt to read back what happened found nothing. The
failure destroyed its own evidence, and it did it every time.

**The units were never the problem.** On the same board, by hand:

```
/usr/lib/systemd/systemd-random-seed save     0.051 s
ifdown -a --read-environment --exclude=lo     1.273 s
systemctl stop systemd-random-seed            0.283 s
```

and the SD card measures 12.9 MB/s for 1 MB writes, 9.8 MB/s for 4 kB writes,
with load 0.00 and no I/O errors. The stalls exist only in the shutdown
transition, and they overran their own configured timeouts severalfold, so no
per-unit timeout was ever going to contain them.

Two changes, both in the overlay, each with its reasoning in the file:

- `etc/network/interfaces` - `allow-hotplug eth0` rather than `auto eth0`, which
  takes `networking.service` out of the blocking path at both ends.
- `etc/systemd/system.conf.d/fishball.conf` - `DefaultTimeoutStopSec=20s` to cap
  any remaining stall, and `RebootWatchdogSec=60s` so the Zynq watchdog resets
  the board if a shutdown stalls regardless.

**Measured before and after, same board, same evening:**

| | before | after |
|---|---|---|
| boot to login | ~75 s | **14.0 s** (3.5 kernel + 10.5 userspace) |
| full reboot cycle | ~29 min, then never reset | **43 s** |
| stalled stop jobs | four | **none** |
| failed units | 0 | 0 |

The watchdog was **not** exercised by that run - the shutdown finished in 20
seconds and never came near it. It is there for the part that is still not
explained: why these particular stops stall during shutdown at all, when every
one of them is instant while the system is up.

## Known defect: unplugging the USB cable loses usb0's address

**Symptom.** The board is running fine, but after you unplug and replug the USB
(OTG) cable, `192.168.2.1` no longer answers. `lsusb` still shows
`0456:b673 PlutoSDR`, the host's `enx…` interface is back with carrier, and the
board has not rebooted — it simply has no address on `usb0`.

**Cause.** `fishball-usb-bind.service` is `Type=oneshot` with
`RemainAfterExit=yes`, and nothing re-triggers it. On replug the gadget
re-enumerates and `usb0` is reconfigured, but systemd still considers the unit
`active (exited)` from the original boot, so the `ip addr add 192.168.2.1/24`
never runs again.

**Workaround: power-cycle the board.** Or, if you can still reach it another way:

```sh
# run on the board
systemctl restart fishball-usb-bind
```

**Why this is not fixed here yet.** The obvious fix — binding the unit's lifetime
to `sys-subsystem-net-devices-usb0.device` — depends on whether the board's `usb0`
netdev actually *disappears* on unplug or merely loses carrier, and with a
configfs gadget it is usually the latter, in which case that fix would not fire
either. Shipping an untested systemd unit into a release rootfs is how this defect
arrived; the fix will land when it has been verified on hardware across a real
replug, not before.

Diagnosing it is quick, and worth knowing because every symptom points at the
wrong thing: the board looks dead, and it is not.

| check | what it tells you |
|---|---|
| `lsusb \| grep 0456:b673` | the gadget is enumerated, so **Linux is running** |
| `dmesg -T \| grep rndis_host` on the HOST | one `register` and no `unregister` since means it has **not** rebooted |
| `cat /sys/class/net/enx…/carrier` | `1` means the link is up; the fault is layer 3 |
| `ip neigh show dev enx…` | `FAILED` means the board is not answering ARP — no address on its side |

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
| all keys removed, on the running board | `ConditionResult=yes`, all six regenerated, `sshd -t` OK, `systemctl restart ssh` clean, fresh login succeeded |

### And on a real first boot, the hedge turned out to be load-bearing

A card was then written from the **published v2.0 asset** — downloaded back,
`SHA256SUMS` checked, `write-card.sh`, keeping the board's existing `BOOT.bin` so
the bitstream was not a variable — and booted. SSH came up on a card that shipped
with no host keys: all six generated, fingerprint different from the previous
card's, `/etc/machine-id` populated, dbus still a symlink, **0 failed units**, both
transmitters at −89.750000 dB before userspace, and
`./devkit selftest --ssh` **23 passed, 0 failed**.

The part worth keeping is *which* unit did it:

```
fishball-sshd-keygen   success / ConditionResult=yes
sshd-keygen            success / ConditionResult=no
```

**Debian's own unit did not fire.** `ConditionFirstBoot` evaluated false on a card
whose `/etc/machine-id` was empty when it was written — PID 1 decides that early
and it did not go the way the documentation implies. So the reasoning above, that
a condition which cannot be tested from a running system is not one to stake SSH
access on, was right for a reason that only a real first boot could show. Without
`fishball-sshd-keygen.service` this card would have come up with no host keys and
no way in.
