# The Debian root: how it works, and why

Reference for [`firmware-modern/debian/`](../firmware-modern/debian/README.md).
That README is the quick start; this page explains what the overlay's units
and settings do and what goes wrong without each of them. For why the board
moved off Buildroot at all, see [`debian-rootfs.md`](debian-rootfs.md).

## Transmitter safety at boot

The AD9361 can transmit at about +19 dBm, so the transmitter is held at maximum
attenuation (−89.75 dB) from power-on until a program deliberately starts a
transmit stream. Three layers cover that time:

| | covers |
|---|---|
| the device tree | probe: `adi,tx-attenuation-mdB = 89750`, applied near the end of `ad9361_setup()`. The TX calibration just before it transmits for a few milliseconds at every power-on ([`IDLE-CASES.md`](../IDLE-CASES.md)) |
| **`fishball-rf-quiesce.service`** | from boot until something opens a transmit buffer |
| the kernel | `patches/0004` mutes when a transmit buffer stops, `0015` when the DAC runs out of samples |

`fishball-rf-quiesce` waits up to 10 s for `ad9361-phy`, writes −89.75 dB to
both channels, reads the values back, and sets the 60 s bound on unattended
cyclic transmits (`tx_cyclic_timeout_ms`, where the kernel has it). It is
ordered before `iiod`, the one process that opens transmit buffers without
being asked; that ordering is the safety mechanism.

`iiod` has `Requires=fishball-rf-quiesce.service`, so **if the quiesce fails,
`iiod` does not start** and there is no network SDR service. The board stays
reachable over USB (see below), and `journalctl -b -u fishball-rf-quiesce -u iiod`
says why. `systemctl start iiod` re-runs the quiesce first.

## The USB route

The USB cable carries a network link (`usb0`, the board at `192.168.2.1`), a
serial console, and libiio. It is the way in when Ethernet is down, so it
starts independently of the network:

```
fishball-usb-gadget.service   Before=iiod.service   builds the USB gadget, mounts FunctionFS
fishball-usb-bind.service     After=iiod.service    attaches the gadget to the USB controller, brings usb0 up
serial-getty@ttyGS0.service                         a login console on the same cable
```

**FunctionFS** is how `iiod` serves libiio over USB from userspace. The gadget
can only be attached once `iiod` has written its USB descriptors, which happens
some time after systemd considers `iiod` started; attaching earlier fails with
`EIO`. So `fishball-usb-bind` waits for `/dev/iio_ffs/ep1`, which `iiod` creates
after writing them, and retries. It runs after every `iiod` start and stop: with
`iiod` down it attaches the gadget without the libiio function, so `usb0` and the
console still come up.

`iiod` gets `-F /dev/iio_ffs` from a wrapper, `fishball-iiod`, that checks the
gadget exists first. Without that check, a failed USB gadget would stop `iiod`
from starting, and with it the network service every host tool uses.

**The MAC addresses** derive from `sha1(hw_serial)`, the same way the factory
`S23udc` script derives them. Your PC names its end of the link after the
`host_addr` MAC (for example `enx00e022338e2c`), so a different derivation would
rename the interface and break any static address or NetworkManager profile
bound to it. `hw_serial` lives in `/mnt/jffs2` on the QSPI flash, not on the SD
card, so the name survives reflashing.

## Board identity

`fishball-identity.service` mints `hw_serial` into `/mnt/jffs2` once, and writes
`/etc/libiio.ini`. libiio serves that file's values as IIO *context attributes*,
and `tools/selftest/sdr_selftest.py` and the MCP server read them. A board whose
serial changes looks like a different unit to anything that keeps a baseline.

`fw_version` carries the release (`v2.1`) and `fw_build` the full `git describe`
(`v2.1-2-ge09d3add`), both read from `/opt/VERSIONS`. They are separate because
MATLAB's ADALM-Pluto support package refuses to connect when `fw_version` has
the shape of a `git describe` string: it tries to raise a compatibility warning
and fails while building it. See [`matlab.md`](matlab.md).

`/opt/VERSIONS` records what was built: the `device-fw` line, the Debian
release, the build time, and every installed package at its exact version.
`/usr/share/fishball/packages.txt` records what was asked for, and why. The base
image is pinned by digest and the packages come from a fixed
snapshot.debian.org date (`BASE` and `DEBIAN_SNAPSHOT` in the `Containerfile`);
`/opt/VERSIONS` records both. The board itself keeps the normal Debian sources,
so `apt update` there gets current packages.

## No identity in the image

`rootfs.tar` is a release asset, so anything in it is on every board flashed
from it.

- **SSH host keys** are deleted from the image. Otherwise every board would
  share one private host key, published on the releases page.
- **`/etc/machine-id`** is empty, which tells systemd this is a first boot.
  `/var/lib/dbus/machine-id` is a symlink to it.

Two units generate host keys on first boot:

| | runs when |
|---|---|
| `sshd-keygen.service` (Debian's) | `ConditionFirstBoot` is true |
| `fishball-sshd-keygen.service` | `/etc/ssh/ssh_host_ed25519_key` is missing |

On a freshly written card, Debian's unit does not fire: `ConditionFirstBoot`
evaluates false even though `/etc/machine-id` is empty. `fishball-sshd-keygen`
is what generates the keys. Keep it. Both run `ssh-keygen -A`, which only
creates missing keys, so they never conflict.

## Differences from Buildroot and from a container image

Each of these fails quietly or blames the wrong thing, which is why the fix
is in the image rather than left to the user.

| symptom | cause | what the image does |
|---|---|---|
| no network, `networking.service` failed | systemd renames `eth0` to `end0`; Buildroot did not | `net.ifnames=0` on the kernel command line |
| avahi publishes the wrong hostname | podman bind-mounts `/etc/hostname` and `/etc/hosts` during a build, so writes to them never reach the image | both files are in `overlay/` |
| host streaming capped at 16 MB buffers | libubootenv's `fw_printenv` exits 0 with empty output for an unset variable, so an `\|\| default` never fires | `fishball-identity` treats empty output as unset |
| ssh dies partway through a tool run, "Permission denied" | OpenSSH 9.8+ `PerSourcePenalties` blocks an address that opens many short connections, which the host tools do | turned off in `sshd_config.d/fishball-penalties.conf` |
| PAM refuses a correct password | the board has no real-time clock and boots with a date before the image was built, so the password looks changed in the future | the root password is dated 1970-01-02 (`chage -d 1 root`) |
| `apt update` rejects Release files as "not valid yet" | the same wrong clock | `systemd-timesyncd` is installed in the image, so the clock is set before `apt` runs |
| installed services never start | the Debian container image ships `/usr/sbin/policy-rc.d`, which blocks service starts | it is deleted |

## Shutdown and reboot

A reboot on this board used to stall for many minutes in stop jobs and then not
reset at all, so the board looked hung and had its power pulled. The stop jobs
themselves were instant when run by hand; they only stalled during shutdown.
The overlay contains it:

- `etc/network/interfaces` uses `allow-hotplug eth0`, not `auto eth0`, so
  `networking.service` does not block boot or shutdown waiting for a cable.
- `etc/systemd/system.conf.d/fishball.conf` sets `DefaultTimeoutStopSec=20s`, so
  a stalled stop job gives up, and `RebootWatchdogSec=60s`, so the Zynq watchdog
  resets the board if shutdown stalls anyway.
- **`systemd-logind` is masked.** Nothing on the board uses it (no login path
  uses `pam_systemd`). It could spin at start-up until its 90 s timeout, and
  because each failure took longer than systemd's 10 s rate-limit window, it
  restarted forever and starved PID 1. A start-limit drop-in with a longer
  window stays alongside, for anyone who unmasks it.

With these, a boot to login takes about 14 s and a reboot about 45 s.

**Pulling the power corrupts the journal.** journald keeps corrupt archives as
`*.journal~`, `journalctl` stops reading at the first one, and they take space
from the 32 MB limit. After a run of hard power cuts:

```bash
# run from: the board
journalctl --disk-usage
rm -f /var/log/journal/*/system@*.journal~
```

If `systemd-logind` is unmasked and spins again, turn on its debug log for one
boot (in `/run`, so it does not persist):

```bash
# run from: the board
mkdir -p /run/systemd/system/systemd-logind.service.d
printf '[Service]\nEnvironment=SYSTEMD_LOG_LEVEL=debug\n' \
  > /run/systemd/system/systemd-logind.service.d/debug.conf
systemctl daemon-reload && systemctl reset-failed systemd-logind
systemctl start systemd-logind        # then: journalctl -u systemd-logind
```

## SD card writes

Buildroot ran from RAM and never wrote to the card. The Debian root does, so:

- every mount is `noatime`, and the root is `commit=30`: at most 30 s of writes
  are lost to a power cut
- journald is capped at 32 MB and syncs every 10 minutes

A power cut loses anything written in the last 30 s, and the filesystem comes
back clean, so nothing warns you. **Run `sync` after deploying anything you care
about.**

`apt` works but is slow: `dpkg` takes minutes on the dual Cortex-A9.
