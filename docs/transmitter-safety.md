# Transmitter safety

What to do before you transmit with this board, what the firmware does to keep
the transmitter quiet when you are not using it, and what it cannot protect
against. Read it before you cable a transmit port to anything. The short version
is in the [README](../README.md#before-you-ever-transmit); the evidence behind
every claim here is in [`IDLE-CASES.md`](../IDLE-CASES.md) and
[`tools/IDLE-CASES.md`](../tools/IDLE-CASES.md).

Terms used below: **TX** and **RX** are transmit and receive. **Attenuation** is
how far the transmit output is turned down, from 0 dB (full power) to −89.75 dB
(the floor, "muted"). A **DMA buffer** is the block of samples a program hands
the kernel to send; opening one starts a transmit stream. A **cyclic** buffer is
one block the hardware repeats forever. The **TX LO** is the transmit local
oscillator, the synthesiser the transmit chain mixes up to RF with. **debugfs**
is the kernel's debug file interface under `/sys/kernel/debug`.

## Before you transmit

1. **Terminate every transmit port**, and never transmit at power into an open
   one (see [the power budget](#a-txrx-loopback-without-an-attenuator-will-destroy-your-receiver)).
2. **Fit at least 20 dB of attenuation in any TX→RX loopback.** The receiver's
   absolute maximum input is +2.5 dBm; the transmitter reaches about +19 dBm.
3. **Take the antenna off any transmit port you do not want radiating when the
   board powers up.** Every power-on emits a few milliseconds at the TX LO on both
   ports, and no software can prevent it
   ([details](#every-power-on-transmits-and-no-software-here-can-stop-it)).
4. **Affirm the channel you will raise, after looking at that port:**
   `./devkit tx-guard affirm 0` for TX1A, `1` for TX2A
   ([details](#raising-output-needs-a-human-on-record)).
5. **Know which target the board runs.** `grep ^ID= /etc/os-release` on the board
   says which root filesystem it has: Debian is the modern target, Buildroot the
   factory one. The protections differ (next section).
6. **On the factory kernel, re-mute after any debugfs `initialize`** and read
   both attenuations back ([why](#debugfs-initialize-on-the-factory-kernel)).

## What the firmware protects, per target

| protection | factory target (5.15, Buildroot) | modern target (6.12, Debian) | limit |
|---|---|---|---|
| probe at maximum attenuation | yes (`patches/0011`) | yes (its device tree) | applied after the power-on calibration, which has already transmitted |
| mute at boot, before anything can stream | `tx_quiesce` in `S21misc` | `fishball-rf-quiesce.service`; `iiod` does not start unless it succeeded | `fw_setenv tx_quiesce 0` turns it off |
| mute when a stream stops | yes (`0004`, `0005`) | yes | fires on buffer teardown only |
| mute when the DAC starves (a killed or stalled program) | yes (`0015`), 250 ms | yes, 250 ms | exempts cyclic streams; fires once |
| bound on a cyclic stream | **off** (`tx_cyclic_timeout_ms` = 0) | **60 s**, armed at every boot | off on the factory target unless you set it each boot |
| TX-disable latch | yes (`0016`), off by default | yes, off by default | root can clear it |
| die-temperature ceiling | yes (`0018`), off by default | yes, off by default | |
| a cached attenuation of zero is never restored | **no**: debugfs `initialize` can key full output | yes (`firmware-modern/patches/0019`) | |

Stock firmware has none of these. At power-on the AD9361 comes up in ENSM `fdd`
(the chip's state machine, with both chains powered) with the TX synthesiser
running and only 10 dB of attenuation, so the port emits LO leakage continuously
with nothing in the DAC and nobody having asked it to transmit. When a
transmission ends, ADI's driver switches back to a silent DDS (the internal tone
generator) and leaves the chain biased. At maximum attenuation that idle output is
negligible, but it warms a die already above 50 °C, and on the power-amplifier
variant it is not a trivial amount of power.

### Muting when a stream stops

`patches/0004` hooks the TX buffer lifecycle the DAC driver already has, and calls
`ad9361_tx_mute()`, ADI's own exported helper, which upstream never calls:

| event | what happens |
|---|---|
| boot | TX at maximum attenuation from the device tree, but **not from the instant power is applied**: see [Every power-on transmits](#every-power-on-transmits-and-no-software-here-can-stop-it). The boot mute is `fishball-rf-quiesce` on the Debian root and `S21misc` on Buildroot |
| a TX buffer starts streaming | TX unmuted: your gain if you set one, else the last you used |
| the buffer stops | TX muted and the synthesiser powered down |

The unmute restores the cached attenuation only if nothing has been set since the
mute (`patches/0005`). Restoring it unconditionally would overwrite a gain set
just before the stream with the previous transmission's value, so asking for
−10 dB could put −60 dB on the wire. Both orders work:

| what you do | what you get |
|---|---|
| set a gain, then start the stream | the gain you set |
| start the stream having set nothing | the last gain you used |

The TX mute needs no device-tree change of its own: the driver reaches the phy
(the `ad9361-phy` device) through the DDS node's existing `clocks` phandle.

**Remove any watchdog script that polls `buffer/enable` to re-apply a gain.** It
is no longer needed, and on a board with a power amplifier it is dangerous: it
applies a fixed gain to both channels a second or two after *any* stream starts,
silently overriding the application. Where to look for one depends on the root
filesystem:

- **Buildroot**: `/mnt/jffs2/autorun.sh` runs at every boot, so a script there
  survives reflashing the kernel, device tree and bitstream, and appears nowhere in
  the firmware source. Check it first.
- **Debian**: *nothing runs `autorun.sh`*. The file can be present and do nothing.
  Look at `systemctl list-units 'fishball*'` and `systemctl --failed` instead.
  `/mnt/jffs2` is mounted on both, because it is in QSPI flash rather than on the
  card.

`tools/selftest/sdr_selftest.py --ssh` reports what is in `/mnt/jffs2` **and**
whether anything on that root filesystem would run it.

### When the program dies: the starve watchdog

The stream-stop mute is keyed to an **event**, buffer teardown, and an event can
be missed. Kill a program that is transmitting *from the board itself* and
`buffer/enable` stays `1`: the IIO core never runs `postdisable`, and without
`0015` the mute never fires and the transmitter stays live. Through a 20 dB loop
the port read −46.7 dBFS against −59.3 dBFS muted, 12.6 dB hotter, with the
program gone ([`tools/IDLE-CASES.md`](../tools/IDLE-CASES.md), case B).

`patches/0015` keys off a **state** instead: if no data reaches the DAC for 250 ms
while the transmitter is on, the driver mutes. That covers a killed program, a
program that stalls without dying, and a buffer that is switched on and never fed.
A killed local transmitter mutes to −89.75 dB in **0.26–0.27 s** (0.26 on 6.12,
0.27 on 5.15), and a normal close still mutes as before.

```bash
# run on the board - how long the DAC may starve before muting, 0 disables
cat /sys/bus/iio/devices/iio:device2/tx_starve_timeout_ms
```

The examples use `iio:device0` for `ad9361-phy` and `iio:device2` for
`cf-ad9361-dds-core-lpc`, the transmit DMA device, which is what the modern
target numbers them. The numbers are not guaranteed across kernels, so in a
script find each device by its `name` file:

```bash
# run on the board
for d in /sys/bus/iio/devices/iio:device*; do echo "$d $(cat $d/name)"; done
```

The watchdog has two limits, covered in the next two sections: it exempts cyclic
streams, and it fires once.

### Cyclic transmits and the 60 s bound

A cyclic transmit hands the hardware one buffer that repeats forever without
software. Outliving the program that started it is the purpose of the feature, so
the starve watchdog leaves cyclic streams alone, and a killed cyclic stream looks
identical to a normal exit. **Every streaming tool in this devkit transmits
cyclically**, so a killed cyclic stream is the ordinary abnormal ending here.

A separate bound covers it, `tx_cyclic_timeout_ms`. The kernel's compiled-in
default is `0`, off.

- **Modern target (Debian root): armed at 60 s on every boot.**
  `fishball-rf-quiesce` writes it before `iiod` starts, in the same unit that mutes
  both attenuators, and `iiod` does not start at all unless that unit succeeded
  (`Requires=`): no proven mute, no network SDR service. The board stays reachable
  over `usb0` to find out why; see
  [`docs/debian-root-reference.md`](debian-root-reference.md#transmitter-safety-at-boot).
  After a cold boot, with nothing run by hand, `tx_cyclic_timeout_ms` reads `60000`.
- **Factory target (Buildroot ramdisk): not armed.** It stays `0` unless you write
  it yourself after each boot (the `echo` below).

```bash
# run on the board - check it, change it, or turn it off
cat /sys/bus/iio/devices/iio:device2/tx_cyclic_timeout_ms   # 60000 after boot (Debian)
echo 10000 > /sys/bus/iio/devices/iio:device2/tx_cyclic_timeout_ms   # this boot only
fw_setenv tx_cyclic_bound 10000    # Debian: a different bound, from the next boot on
fw_setenv tx_cyclic_bound 0        # Debian: no bound at all, from the next boot on
```

The timer is armed when the block is submitted, not when the program dies, so the
bound also mutes a healthy, unattended cyclic transmit 60 s after it started.

`tx_cyclic_bound` is a **separate** switch from `tx_quiesce` on purpose. They cover
different things (the attenuators at boot; an unattended stream hours later), and
sharing one switch would mean that turning off the boot mute for an unrelated
reason also unbounded every cyclic transmit.

The one tool here that runs into the bound is `tools/sample_gpio_clock.py`, which
holds a cyclic stream open until Ctrl-C. Its RF goes quiet after 60 s; its **pins
do not**, because the sample-GPIO nibble never reaches the DAC. It prints the bound
when it starts with a raised gain, so a carrier disappearing after a minute does
not read as a fault.

### The starve watchdog fires once

It does not re-arm. Once it has muted, the driver believes the transmitter is
muted, and data arriving again does not change that; only a fresh buffer enable
does. So after a starve-mute a gain write raises the attenuator and **nothing
re-mutes it**, not the driver and not stream stop:

```
atten0=-30.000000  LO_pd=1  buf=1      (gain written AFTER the watchdog fired)
```

What keeps that port silent is the **powered-down TX LO**, not the attenuator.
Never read `hardwaregain` on its own and conclude anything; read
`out_altvoltage1_TX_LO_powerdown` beside it.

### Refusing to transmit at all

```bash
# run on the board
echo 1 > /sys/bus/iio/devices/iio:device0/tx_disable
```

A latch that forces maximum attenuation and **cannot be cleared by the debugfs
routes that can otherwise raise the transmitter**: `initialize`, which re-applies
the device-tree attenuation to both channels, and `bist_tone` mode 1, which
injects a tone at the transmit port and sends it out through the power amplifier.
Both are reachable over port 30431 (`iiod`), which has no authentication.

Its limits: clearing it takes a root write to the same sysfs file, so it is no
protection against anything that already has root; the claim is only that
**debugfs cannot clear it**. It reads `0` unless somebody sets it, so it protects
nothing by default.

### Refusing to transmit when hot

```bash
# run on the board - millidegrees C; 0 (the default) disables it
echo 60000 > /sys/bus/iio/devices/iio:device0/tx_temp_limit
```

Above the limit, requests to *lower* the attenuation are refused. Muting is never
blocked, so the failure direction is silence.

**It also makes transmit code testable with an antenna connected.** Arm it
*below* the die temperature and every request to get louder is refused **and
logged**, while muting still works:

```bash
# run on the board - 1 C, so nothing can ever get louder
echo 1000 > /sys/bus/iio/devices/iio:device0/tx_temp_limit
dmesg | tail -1
# ad9361 spi0.0: die at 40.351 C is over the 1.000 C transmit limit - staying muted
```

The question then becomes *"did the driver ask to get louder?"* rather than
*"what came out of the port?"*, which can be answered safely. Confirm the gate is
live with an explicit `-60 dB` write first: an empty log proves nothing if nothing
was armed.

### Raising output needs a human on record

Nothing on this board can tell what is attached to a transmit port: there is no
directional coupler and no detector on either one. So the devkit records what a
person says, **per channel** (channel 0 is TX1A and channel 1 is TX2A, two
separate SMAs), and refuses to raise that channel without it:

```bash
# run from: the repo root
./devkit tx-guard affirm 0        # only after LOOKING at TX1A
./devkit tx-guard check 0         # exit 0 affirmed, 3 not
./devkit tx-guard revoke both     # withdraw, and force maximum attenuation
```

The record lives in the board's `/tmp`, which is tmpfs (in RAM), so a reboot
withdraws it. `./devkit selftest --loopback`, `tools/sample_gpio_clock.py` and
`tools/modulation-gallery/board.py` all refuse without it. `./devkit selftest` on
its own and `./devkit gpio-check` never command output, so they are checked
rather than gated (see [Opening a transmit buffer](#opening-a-transmit-buffer-is-not-a-neutral-act)).
**Muting is never gated**: it has to work when ssh is down.

**One affirmation covers one run** of the harnesses in `tools/tx-idle-cases/`:
they call `tx-guard.sh revoke both` on the way out, which removes the affirmation
as well as muting, including after a clean run. A back-to-back re-run being
refused is the gate working.

This raises the floor; it is not a lock. A direct write to
`out_voltageN_hardwaregain` walks past it, and the affirmation is an ordinary file
in world-writable tmpfs that any process can forge. A forged one is worse than the
direct bypass, because it manufactures a false record that a person vouched for a
port.

Over a 50 dB attenuated loopback, **the mute costs no output power**: commanded
and applied attenuation matched to 0.01 dB at every point including 0 dB, and
received level tracked commanded gain across 40 dB within 1.9 dB.

## What the firmware does not protect against

### Every power-on transmits, and no software here can stop it

**About one second after power is applied, both TX1A and TX2A emit a narrowband
burst of roughly 4 ms at the transmit LO frequency**, around 50 dB above two
control bands 1.0 and 3.0 MHz below it. Both control bands are on the same side,
because the capture (4 MSPS, centred under the LO) has no room above it, so an
event confined to the upper half-band would not be rejected by this test.

It was captured with a second receiver (a HackRF One) cabled to each transmit port
through a pad, recording continuously across power cycles; the board's own
receiver cannot see it, because it powers up with the board. The burst saturated
that receiver through 20 dB of attenuation, so its strength is a lower bound: at or
above the loudest calibrated point, an equivalent commanded attenuation of −20 dB.
Pinning it exactly needs a re-run at lower receiver gain.

**It is normal AD9361 behaviour, not a bug.** `ad9361_tx_quad_calib()` drives an
NCO tone (a numerically generated test tone) through the transmit path to correct
I/Q imbalance. Transmitting is the mechanism, and the function aborts if the TX LO
is powered down. It runs at `ad9361.c:5308`, *before* `ad9361_set_tx_atten()`
applies the device tree's value at `:5326`. Every AD9361 design does this; the
PGA-102+ amplifier on transmit is what makes it loud here.

**So there is no software fix.** `tx_quiesce`, the affirmation gate, the starve
watchdog and the `tx_disable` latch all act in userspace or later in the driver,
all too late. The mitigation is operational:

> **Do not leave an antenna on a transmit port you do not want radiating when the
> board is powered up.**

The duty cycle is negligible and the emission is in the 2.4 GHz ISM band, so this
is something to know about rather than a licensing problem. The measurements are in
[`IDLE-CASES.md`](../IDLE-CASES.md#the-capture-was-taken-and-the-boot-window-is-not-quiet).

### Opening a transmit buffer is not a neutral act

**The unmute restores whatever gain the last stream used, and it fires on a bare
buffer enable, with nothing having asked for output.** On a board reading fully
muted on both channels:

```
before anything                 atten0=-89.750000  LO_pd=1  buf=0
after a bare buffer enable      atten0=-61.500000  LO_pd=0  buf=1
```

A **28.25 dB** raise, performed by the kernel, bounded only by the loudest gain
used since boot. So "I wrote −89.75 dB before streaming" guarantees nothing, and
neither does "this program never sets a gain". Two rules follow:

- **Write your attenuation *after* the buffer starts, and read it back.** Anything
  written before the enable is what the restore overwrites.
- **Mute *before* you tear the buffer down, never after.** The stream-stop hook
  snapshots whatever attenuation it finds into the cache and only then applies
  maximum, so closing first hands your gain to whoever streams next.
  `tools/tx-guard.sh`'s `reap` documents the ordering for the same reason.

A program that means to stay silent while streaming therefore has to check: read
both attenuators immediately after the enable and stop if either moved. All four
of the devkit's streaming tools do (`tools/tx_gate.py:assert_quiet_after_enable`),
and an unreadable attenuator counts as a failure, not as silence.

### debugfs `initialize` on the factory kernel

The kernel unmute restores the attenuation that was in force before it muted. On
the factory kernel that cached value lives in the struct `ad9361_clear_state()`
wipes with `memset`, and debugfs `initialize` calls it. **Zero millidecibels of
attenuation is full output**, so:

```bash
# run on the board. On the factory kernel, with an antenna fitted, do NOT.
echo 1 > /sys/kernel/debug/iio/iio:device0/initialize
# ...then anything at all that opens a transmit buffer...
```

leaves the transmitter keyed flat out with nobody having asked for it. On hardware,
TX2 read `0.000000 dB` after exactly that sequence, with no gain written by the
application or the operator at any point in that boot.

The modern target fixes it with
[`firmware-modern/patches/0019`](../firmware-modern/patches/README.md#0019-never-restore-a-cached-attenuation-of-zero):
the cache moves to `struct ad9361_rf_phy` and is seeded at probe with maximum
attenuation, so "nothing cached yet" means muted rather than loud. It is the third
safety-relevant field moved out of that struct, after the `tx_disable` latch and
the temperature limit.

**On the factory kernel, treat a debugfs `initialize` as something that requires
re-muting afterwards**, and read both attenuations back:

```bash
# run on your HOST
U=ip:192.168.2.1
for c in 0 1; do iio_attr -u $U -c -o ad9361-phy voltage$c hardwaregain; done
```

## Rules for programs that transmit

**A mute you did not read back is not a mute.** A write to
`out_voltageN_hardwaregain` can fail, and a `2>/dev/null` or an
`except Exception: pass` hides the failure in exactly the message that says the
port is quiet. Every mute in this repo writes, reads back, compares against
−89.75 dB, and says **TREAT THAT PORT AS LIVE** when the read-back disagrees. A
helper that returns pass/fail is only half of it: a caller that discards the
return value moves the silent failure one level up.

Shell scripts that run on the board:

- **Trap `HUP`, not just `EXIT INT TERM`.** Board-side scripts run over ssh, and a
  dropped session delivers `HUP`. A shell that traps only the other three dies
  untrapped and leaves whatever it started running. For
  `tools/tx-idle-cases/dds-tone.sh` that is a DDS tone with no DMA buffer, which
  neither the stream-stop mute in `0004` nor the starve watchdog in `0015` can
  reach.
- **Install one handler.** `trap` replaces, it does not append. With two
  `trap … EXIT` lines in one script only the second ever runs.
- **Mute before you tear the buffer down, on the error paths too.** The aborts are
  where this is usually missed, and an abort is when the attenuator is raised (see
  [Opening a transmit buffer](#opening-a-transmit-buffer-is-not-a-neutral-act)).
- **A trapped signal does NOT terminate the shell: the handler must `exit`.** This
  matters most, and adding `HUP` without it is worse than not trapping at all. The
  handler runs and execution **resumes at the next statement**: a script with
  `trap h EXIT INT TERM HUP PIPE QUIT` reaches its own final line after a `HUP`. In
  a harness that means the handler mutes and revokes, the next step opens a TX
  buffer, and the kernel's cache restore (which revoking *arms*, by leaving both
  attenuators at exactly −89.75) puts the port back at the previous stream's gain
  with the operator's session already gone. Shape it like this:

  ```sh
  # run on: the board
  trap '_quiet_on_exit' EXIT
  trap '_quiet_on_exit; trap - EXIT; exit 130' INT
  trap '_quiet_on_exit; trap - EXIT; exit 143' TERM HUP PIPE QUIT
  ```

  and mask the signals as the handler's first statement (`trap '' INT TERM HUP
  PIPE QUIT`), because with `PIPE` trapped on a dead stdout every remaining `echo`
  re-enters it.
- **`QUIT` does not fire under dash.** dash accepts the trap (it lists in `trap`)
  and then dies without running it; seen twice on this board. Keep it for other
  shells; do not rely on it here. `INT` does fire, but over a plain
  `ssh host "sh script"` with no pty, Ctrl-C never reaches the board: the session
  drops and the script gets `HUP` and `PIPE` instead.
- **`nohup` silently drops the `HUP` handler.** POSIX shells do not install a trap
  for a signal that was ignored on entry, and `nohup` ignores `SIGHUP`. A script
  launched `nohup … &` has no HUP handler however it was written; on this board
  `dds-tone.sh` run that way was found gone with its DDS scales still at 0.25 and
  no exit line in its log. Run it in the foreground, or follow it with an explicit
  `off`.

> ### A TX→RX loopback without an attenuator will destroy your receiver
>
> The receiver is the fragile end: **+2.5 dBm is the AD9361's absolute-maximum RF
> input**. **This board is sold in a variant with a power amplifier on
> transmit**, which most Pluto advice does not account for. The PA is a
> Mini-Circuits [**PGA-102+**](https://www.minicircuits.com/pdfs/PGA-102+.pdf):
>
> | GHz | 0.05 | 0.8 | 2.0 | 3.0 | 4.0 | 6.0 |
> |---|---|---|---|---|---|---|
> | **Gain (dB)** | **17.7** | 15.9 | 14.0 | 12.5 | 11.5 | 10.4 |
>
> with P1dB (the 1 dB compression point) around **+17.5 dBm**. Plan for **about
> +19 dBm** flat out, roughly **16 dB above what its own receive port survives**.
> That figure is the self-test's estimate, scaled up from a quieter measurement and
> capped at the amplifier's compression point; nobody has put a power meter on the
> port.
>
> <sub>This table and these figures are the canonical copy; `tools/selftest/README.md`
> and the agent skill point here. Update them here first.</sub>
>
> **Do not transmit at power into an unterminated port.** An open or shorted
> connector reflects everything back into the output stage. Neither the AD9361
> datasheet (TX specified into a matched 100 Ω load, ~6.5 dBm max) nor the
> PGA-102+ datasheet states any tolerance for an open, a short or high VSWR, so
> treat it as unspecified and always terminate.
>
> **Fit at least 20 dB of attenuation** in any loopback. More is safe too, but for
> *measuring* the board 20 dB is also the best choice: the board leaks some transmit
> signal straight into its own receiver, and with 50 dB in the cable that leak is as
> strong as the loop above about 1.5 GHz
> ([details](measured-performance.md#the-boards-own-tx-to-rx-leak)). Start at
> maximum attenuation and raise power in steps.
> [`tools/selftest/`](../tools/selftest/README.md) does all of this and never
> transmits with less than 35 dB of its own attenuation. The non-PA variant is
> 10–18 dB quieter; check which you have before relying on that.
