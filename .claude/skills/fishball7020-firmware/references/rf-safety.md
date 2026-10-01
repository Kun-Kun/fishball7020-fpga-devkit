# Transmitting with this board without destroying it

**The receiver is the fragile end.** The AD9361's RX input is rated to
**+2.5 dBm** peak (AD9361 data sheet Rev. G, Table 11, Absolute Maximum
Ratings: "RF Inputs (Peak Power) 2.5 dBm"). Every decision here is sized
against that number.

The same table gives the thermal limits `./devkit temps` reports: maximum
junction temperature **110 °C**, operating range −40 to +85 °C. The −65 to
+150 °C row is *storage*, not an operating range.

## This board may have a power amplifier

It is sold "with PA" and "without PA", and the vendor does not publish the
difference. The PA (power amplifier) is a Mini-Circuits **PGA-102+**, whose
gain falls with frequency:

| GHz | 0.05 | 0.8 | 2.0 | 3.0 | 4.0 | 6.0 |
|---|---|---|---|---|---|---|
| **Gain (dB)** | **17.7** | 15.9 | 14.0 | 12.5 | 11.5 | 10.4 |

P1dB is about +17.5 dBm. Plan for **about +19 dBm** flat out, roughly **16 dB
above what its own receive port survives**. That figure is the self-test's
estimate (scaled up from a quiet measurement, capped at the PA's compression
point), not a power-meter reading: never write "+19 dBm measured".

<sub>Canonical copy of this table: `docs/transmitter-safety.md`. Change it
there first, then mirror it here.</sub>

Sizing a loopback for a bare AD9361 (+7 dBm), as most Pluto advice does, is
wrong by 10-18 dB on this board.

`tools/selftest/sdr_selftest.py --loopback` reports which variant a board is,
by comparing measured loop gain against both models.

## Rules

- **Never loop TX to RX without an attenuator.** Fit at least 20 dB. More is
  equally safe, but for *measurement* use exactly 20 dB: the board's own
  TX->RX leak equals a 33-60 dB pad on channel 0 above 1 GHz, so a 50 dB loop
  there measures the leak as much as the cable (see `measuring.md`).
- **Never transmit into an antenna** without a licence for the frequency. This
  board covers the FM broadcast band, and with the PA it is not a trivial
  transmitter. The MCP server
  ([Fishball7020-mcp](https://github.com/matsvandamme/Fishball7020-mcp)) has a
  safety gate: its tone, IQ and waveform tools refuse anything outside the EU
  licence-free bands (433, 868, 2400, 5800 MHz) or over their power limit,
  unless the call gives an `override_reason` (checked by TypeSafe when
  `TYPESAFE_API_KEY` is set) or `force=true`. The gate is advice and `force`
  exists because the operator decides, so a refusal is a reason to stop and
  ask the operator, never one to reach for `force` yourself.
- Start at maximum attenuation and work down, measuring as you go. Never start
  loud and back off.
- The self-test never transmits with less than **35 dB** of its own
  attenuation: worst case (full-scale drive, 18 dB of PA gain, no external
  pad) that is -10 dBm, 12.5 dB under the RX rating.

## TX muting in this firmware

`patches/0004` mutes the transmitter whenever no DMA buffer is streaming, and
unmutes when one starts. `patches/0005` makes that unmute non-destructive:

| What you do | What you get |
|---|---|
| set a gain, then start the stream | the gain you set |
| start the stream having set nothing | the last gain you used |
| stop the stream | maximum attenuation, TX synthesiser down |

**`postdisable` (the buffer-close hook) is not a guarantee.** Kill a
transmitting process *on the board* and `buffer/enable` stays `1`, the hook
never runs, and the transmitter stays live: through a 20 dB loop the port read
12.6 dB hotter than muted with the process gone. Do not repeat the old claim
(once in `patches/0004` and this skill) that teardown on file close always
mutes. Cases: [`tools/IDLE-CASES.md`](../../../../tools/IDLE-CASES.md).

`patches/0015` closes most of that gap by muting on **state** rather than on an
event: no DMA block for `tx_starve_timeout_ms` (250 ms by default) and the
transmitter is attenuated, about 0.26-0.27 s from the kill on both kernels (the
250 ms plus the attenuator write). Events can be missed; "the DAC is not being
fed" cannot.

```bash
# run on the board
cat /sys/bus/iio/devices/iio:device2/tx_starve_timeout_ms   # 0 disables
cat /sys/bus/iio/devices/iio:device2/tx_cyclic_timeout_ms   # 60000 on the Debian root, 0 on Buildroot; 0 = off
cat /sys/bus/iio/devices/iio:device0/tx_disable             # latch, 0 = off
cat /sys/bus/iio/devices/iio:device0/tx_temp_limit          # millidegC, 0 = off
```

**Cyclic transmits are exempt from 0015**: the hardware repeats one buffer
forever, and outliving the caller is what `CYCLIC 1` is for, so a kill looks
exactly like a normal return. `tx_cyclic_timeout_ms` bounds that instead.

The **driver** default is `0` (off), so nothing changes for other users of
these patches. **The modern target's Debian root arms it at 60 s on every
boot** from `fishball-rf-quiesce`, the unit that also mutes both attenuators,
ordered before `iiod`. **The factory Buildroot ramdisk does not**: it leaves
the driver default `0`, so a killed cyclic stream there runs until something
stops it. On Debian, change it with `fw_setenv tx_cyclic_bound <ms>`, or `0`
for no bound. It is a separate variable from `tx_quiesce` so that turning off
the boot mute does not also unbound every cyclic transmit. It matters because
every streaming tool in the devkit transmits cyclically, so a killed cyclic
stream is the ordinary abnormal ending on this board.

**`tx_disable` closes the two routes that raise the transmitter without
looking like transmitting**: debugfs `initialize`, which re-applies the
device-tree attenuation to both channels, and `bist_tone` mode 1, which injects
at the transmit port and goes out through the PA. Both are reachable over port
30431, which has no authentication. The latch lives in `struct ad9361_rf_phy`
and not in `ad9361_rf_phy_state`, because `ad9361_clear_state()` memsets the
latter and `initialize` calls it: a latch kept there is cleared by the very
thing it defends against.

**Both mute mechanisms are needed.** At 900 MHz, with the receive LO offset by
1 MHz so leakage is distinguishable from the receiver's own DC offset: muting
the attenuators alone leaves residual LO **26 dB above the noise floor**;
powering the synthesiser down as well takes it a further **19.9 dB**, to
within 6 dB of the floor. These are ratios and are board properties. Do not
convert them to dBm at the port: no receive gain was recorded, there was no
positive control, and any port dBm here inherits the unmetered +19 dBm figure.
Neither mechanism is sufficient alone. Measuring at DC will not show this,
because RX LO = TX LO puts the leakage exactly where the receiver's own offset
lives.

A script polling `buffer/enable` to re-apply a gain is a workaround for the
pre-0005 behaviour: delete it, it silently overrides the application. Look in
`/mnt/jffs2/autorun.sh` (Buildroot only; Debian does not run it).

## Measuring, not guessing

Received levels are dBFS (decibels relative to the converter's full scale)
against a **12-bit** converter (full scale ±2047). Transmit is **16-bit**:
scaling transmit samples to ±2047 emits 24 dB low.

RX gain is not linear in the way its label suggests: the AD9361's gain table
changes the LNA/mixer word at commanded 5, 17, 27, roughly 31-37, 52, and
every step above 63, and the real gain steps by up to 10 dB there while the
label claims 1 dB. **38-51 dB is the widest window with no transition in it**
in any band, and the only place a gain sweep means anything. A line fitted
across the whole range reports ~0.65 dB/dB for a healthy front end. See
`ad9361-gain-tables.md`.

The legal gain range also moves with frequency: `[-1, 73]` below 1.3 GHz,
`[-3, 71]` to 4 GHz, `[-10, 62]` above. Writing outside it returns `-22 EINVAL`.

## Stopping a transmission is two steps, in this order

A one-shot buffer finishes by itself. A **cyclic** one does not: the DMA keeps
feeding the DAC from the same buffer with no further help from the writer.

**Mute first, then kill the writer.** Killing the writer first leaves a window
where the DMA is still running and nothing is holding the attenuation.

**Then make sure the writer is gone.** A trap that mutes on SIGTERM can read
back `-89.750000 dB` while `iio_writedev` is still running: muted but still
streaming. Clear it explicitly:

```bash
# run on your HOST (or on the Debian board; Buildroot has no pkill)
pkill -x iio_writedev
```

**Then read the hardware back, not the log.** A script printing "muting"
proves only that the line executed. Check all four; the last catches what the
others miss:

```bash
# run on your HOST
U=ip:192.168.2.1
for c in 0 1; do iio_attr -u $U -c -o ad9361-phy voltage$c hardwaregain; done
iio_attr -u $U -c -o ad9361-phy altvoltage1 powerdown
pgrep -x iio_writedev
for t in 0 1 2 3 4 5 6 7; do
  iio_attr -u $U -c -o cf-ad9361-dds-core-lpc altvoltage$t scale
done
```

Never skip the DDS sweep: a leftover DDS (the FPGA's built-in tone generator)
transmits **independently of the DMA path**, so a muted attenuator and a dead
writer say nothing about it. All eight scales must read `0.000000`.

**Trap `HUP` as well as `EXIT INT TERM`.** A board-side script is almost always
run over ssh, and a dropped session delivers `SIGHUP`; a shell that traps only
the other three dies untrapped and whatever it held up stays up. For a DDS
tone (as in `tools/tx-idle-cases/dds-tone.sh`) that means a tone the firmware
cannot stop: it opens no DMA buffer, so neither 0004's stream-stop mute nor
0015's starve watchdog can reach it. Install **one** handler per signal:
`trap` replaces, it does not append, so of two `trap ... EXIT` lines only the
second runs.

**A trapped signal does NOT terminate the shell: the handler must `exit`.**
This rule matters most; adding `HUP` without it is worse than not trapping at
all. The handler runs and execution **resumes at the next statement**, so a
script with `trap h EXIT INT TERM HUP PIPE QUIT` reaches its own final line
after a `HUP`. In a multi-case script the next case then opens a TX buffer,
and the kernel's cache restore (which a revoke *arms* by leaving both
attenuators at exactly −89.75) puts the port back at the previous stream's
gain with the operator gone. Shape it like this:

```sh
# run on: the board
trap '_quiet_on_exit' EXIT
trap '_quiet_on_exit; trap - EXIT; exit 130' INT
trap '_quiet_on_exit; trap - EXIT; exit 143' TERM HUP PIPE QUIT
```

and mask the signals as the handler's first statement (`trap '' INT TERM HUP
PIPE QUIT`), because with `PIPE` trapped on a dead stdout every remaining
`echo` re-enters the handler.

**`QUIT` does not fire under dash** (Debian's `/bin/sh`): on this board dash accepts and
lists the trap, then dies without running it. Keep it for other shells; do not
rely on it here. `INT` does fire, but over a plain `ssh host "sh script"` with
no pty, Ctrl-C never reaches the board: the session drops and the script gets
`HUP` and `PIPE` instead.

**`nohup` silently drops the `HUP` arm.** POSIX shells do not install a trap
for a signal ignored on entry, and `nohup` ignores `SIGHUP`, so a script
launched `nohup … &` has no HUP handler however it was written. Run it in the
foreground, or follow it with an explicit `off`.

**A mute that swallows its errors is worse than no mute.** Write, read back,
compare, and say so when the read-back disagrees:

```sh
# run on: the board
mute_both() {
  _bad=0
  for _c in 0 1; do
    echo -89.75 > "$PHY/out_voltage${_c}_hardwaregain" 2>/dev/null || { _bad=1; continue; }
    case "$(cat "$PHY/out_voltage${_c}_hardwaregain")" in
      -89.7*) : ;;
      *) echo "MUTE DID NOT LAND on ch$_c - TREAT THAT PORT AS LIVE" >&2; _bad=1 ;;
    esac
  done
  return $_bad
}
```

Then **act on the return value**: a helper that reports failure to callers
that discard it is the same silent failure one level up.

**Mute before you tear the buffer down, on every path including the error
paths.** The kernel's stop hook snapshots whatever attenuation it finds at
destroy time and restores it on the *next* buffer enable, by any program, with
no affirmation asked for: a bare buffer enable on a board idling at
`-89.75 dB` comes up at `-61.5 dB`. An abort path that destroys first arms its
own raised gain for whoever streams next. Happy paths usually get this right;
error paths are where it is missed.

**Never `pkill -f` a script by its filename** from a shell whose own command
line contains that filename: `pkill` matches and kills that shell
mid-sequence, typically between the mute and the verification. Kill by PID, or
use a bracket pattern (`[f]oo`).

**`pkill` does not exist on the Buildroot board.** There, `pkill -9 iio_writedev
2>/dev/null` does nothing silently, and a starve-watchdog test built on it
reports the watchdog broken while the writer keeps re-arming it. On Buildroot:
`ps`, then `kill -9 <pid>`, then `ps` again. (Debian has `pkill`.)

## What protects the transmitter when nothing is streaming

**Three layers**, each covering a window the next one cannot:

| | covers | mechanism |
|---|---|---|
| the device tree | from `ad9361_setup()`'s attenuation write at `ad9361.c:5326` onward. **Not** the whole of setup: the TX quad calibration at `:5308` transmits before it, so every power-on emits a few ms at the TX LO on both ports, with no software fix | `adi,tx-attenuation-mdB = 89750` |
| the boot quiesce | from then until a DMA buffer starts | `S21misc`'s `tx_quiesce` (Buildroot) or `fishball-rf-quiesce.service` (Debian). On Debian **iiod `Requires=` it**: no proven mute, no SDR service (usb0 still comes up, without USB libiio) |
| the kernel | while streaming, and after it stops | `0004` mutes on buffer close, `0015` when the DAC starves |

Verify the middle one on a running board. **The command differs by userspace**:

```bash
# run on the board - Buildroot
grep -c tx_quiesce /etc/init.d/S21misc
# run on the board - Debian (there is no /etc/init.d/S21misc)
systemctl is-active fishball-rf-quiesce     # -> active
journalctl -b -u fishball-rf-quiesce        # -> "both transmitters at -89.75 dB"
```

The quiesce exists because the AD9361 comes up in ENSM `fdd` (the chip's
state machine, in full-duplex mode) with the TX chain biased and only 10 dB of
attenuation, so the port emits LO leakage from power-on with nothing in the
DMA. It sets **attenuation only, not the TX LO**: powering the synthesiser down
at boot would leave a later stream transmitting into a dead LO, silently.

> **On systemd, a unit with a dependency cycle does not fail: it disappears.**
> `DefaultDependencies=no` with `Before=sysinit.target` *and*
> `WantedBy=sysinit.target` is a cycle, and systemd breaks it by deleting the
> job:
>
> ```
> sysinit.target: Found ordering cycle on fishball-rf-quiesce.service/start
> sysinit.target: Job fishball-rf-quiesce.service/start deleted to break ordering cycle
> ```
>
> The board then boots without the safety unit and reports no failure;
> `systemctl is-active` says `inactive`, not `failed`. Order a safety unit with
> ordinary dependencies (`After=sysinit.target`, `Before=iiod.service`,
> `WantedBy=multi-user.target`), and check `journalctl -b -u` for its
> read-back line rather than trusting that it ran.

From then on `patches/0004` hands muting to the kernel, which unmutes when a TX
DMA buffer starts and re-mutes when it stops. That is what mutes the radio when
a writer is killed.

**What that unmute restores is a third thing to check.** It restores a *cached*
attenuation, and on `firmware/` (and on `firmware-modern/` before patch `0019`)
that cache lives in the struct `ad9361_clear_state()` memsets. Zero mdB is
full output, so:

```bash
# run on the board - DO NOT do this with an antenna fitted on an
# unpatched kernel. Result: TX2 at 0.000000 dB.
echo 1 > /sys/kernel/debug/iio/iio:device0/initialize
# ...then anything that opens a transmit buffer...
```

`firmware-modern/patches/0019` moves the cache out of that struct and seeds it
at probe with maximum attenuation, so "nothing cached yet" means muted. **The
same code is still on `firmware/`.** On the factory kernel, treat a debugfs
`initialize` as requiring a re-mute afterwards, and read both attenuations
back.

**In ordinary operation, with no debugfs involved, that cache restores the
last stream's gain.** On a board that reads fully muted:

```
before anything                 atten0=-89.750000  LO_pd=1  buf=0
after a bare buffer enable      atten0=-61.500000  LO_pd=0  buf=1
```

That is a 28.25 dB raise by the kernel, with nothing having asked for gain and
no affirmation on record. It can only restore a value some earlier stream
used, so it is bounded by the loudest gain used since boot. Hence **a tool
must mute BEFORE it tears its buffer down, never after**: the stop hook
snapshots whatever attenuation it finds and *then* applies maximum, so closing
first hands the cache your loud value for the next program. `tools/tx-guard.sh
reap` documents this. **Four tools in the devkit stream**: the selftest,
`sample_gpio_clock.py`, `modulation-gallery/board.py` and
`tx-gpio-bitmap-check.py`. All four mute before teardown and check **both**
attenuators immediately after every buffer enable, failing on an unreadable
value rather than assuming quiet, because the enable itself can raise one. Any
new streaming tool (including the MCP's `tx_disable` path) must do the same.

**The starve watchdog does not re-arm.** Once `0015` has fired, the driver
believes the transmitter is muted; data resuming does not change that, and
only a fresh buffer enable does. So after a starve-mute a gain write raises
the attenuator and *nothing* re-mutes it, neither the driver nor stream stop:

```
atten0=-30.000000  LO_pd=1  buf=1     (gain written AFTER the watchdog fired)
```

What keeps the port silent there is the powered-down TX LO, not the
attenuator. Never read `hardwaregain` alone and conclude anything: read
`out_altvoltage1_TX_LO_powerdown` with it.

**The affirmation gate, and what it is not.** Antenna presence on TX cannot be
measured on this board (no coupler, no detector, on either port).
`tools/tx-guard.sh` records what a person says is on a port, per channel (0 is
TX1A, 1 is TX2A, two separate SMAs), and refuses to raise that channel without
it; the record lives in the board's `/tmp`, so a reboot withdraws it.
`tools/tx_gate.py` is the host-side adapter and shells out to
`./devkit tx-guard`, so there is one rule and one store.

```bash
# run from: the repo root
./devkit tx-guard affirm 0        # only after LOOKING at TX1A
./devkit tx-guard check 0         # exit 0 affirmed, 3 not - for your own tools
./devkit tx-guard revoke both     # withdraw, and force maximum attenuation
```

Three host tools ask it before commanding output: `./devkit selftest --loopback`
(exit 1 when refused), `tools/sample_gpio_clock.py` and
`tools/modulation-gallery/board.py`. `./devkit selftest` without `--loopback` is
untouched, and **`tools/tx-gpio-bitmap-check.py` never commands output**, so it
is checked rather than gated. **Quiet is never gated**: muting has to work when
ssh is down.

Do not say a refused run "raised nothing" without checking: an unaffirmed
`--loopback` run still enables a TX buffer for the *internal digital* loopback
test, by design, which is why every enable is followed by an attenuator read.
The defensible claim is that **no path commands output without an affirmation,
and the paths that enable a buffer without one are verified not to have raised
the attenuators**.

The gate raises the floor; it is not a lock. A direct write to
`out_voltageN_hardwaregain` bypasses it, and the affirmation is an ordinary
file in world-writable tmpfs that any process can forge. `0016`'s `tx_disable`
latch inside `ad9361_set_tx_atten()` is the one thing *debugfs* cannot clear,
but it reads **0** on this board unless someone sets it, and it is itself a
root-writable attribute, so it is no answer to a forged affirmation. Set it
when the board should not transmit at all:

```bash
# run on the board
echo 1 > /sys/bus/iio/devices/iio:device0/tx_disable
```

To test this class of bug safely with an antenna connected, first arm the
thermal gate below the die temperature:

```bash
# run on the board
echo 1000 > /sys/bus/iio/devices/iio:device0/tx_temp_limit    # 1 C
```

Every request to get *louder* is then refused and logged, while muting still
works, so the question becomes "did the driver ask?" rather than "what came out
of the port?". `dmesg` answers it:

    ad9361 spi0.0: die at 40.351 C is over the 1.000 C transmit limit - staying muted

No line means nothing asked to get louder. Confirm the gate is live first by
making an explicit `-60 dB` write and seeing it refused, or a silent log proves
nothing.
