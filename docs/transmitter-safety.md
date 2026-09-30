# Transmitter safety

What the firmware does to keep the transmitter quiet when you are not using it,
and the power budget you need to know before you cable a transmit port to
anything. The short version is in the [README](../README.md#before-you-ever-transmit).

**Stock firmware leaves the transmitter running.** Measured at power-on, the
AD9361 comes up in ENSM `fdd` with the TX synthesiser going and only 10 dB of
attenuation, so the port emits LO leakage continuously even though nothing is
in the DAC DMA and nobody has asked it to transmit. When a transmission ends,
ADI's driver reverts to a silent DDS but leaves the chain biased.

Idling like that is not in itself a damage risk, since at maximum attenuation
the output is negligible (−89.75 dB below full scale). But there is no reason
to keep a transmitter energised that you are not using. It warms a die already
above 50 °C, and on the **PA variant it is not a trivial amount of power**.

**Do not transmit at power into an unterminated port.** An open or shorted
connector reflects everything back into the output stage. Neither the AD9361
datasheet (TX specified into a matched 100 Ω load, ~6.5 dBm max) nor the
PGA-102+ PA datasheet (~+17.5 dBm here) states any tolerance for an output
open, short or high VSWR, so treat it as unspecified and always terminate. The
receiver does have a hard number: **+2.5 dBm is the AD9361's absolute-maximum
RF input**. That is why every loopback here goes through an attenuator.

**This build fixes it in firmware.** `patches/0004` hooks the TX buffer
lifecycle the DAC driver already has:

| Event | What happens |
|---|---|
| boot | TX attenuated to maximum by the device tree — but **not from the instant power is applied**: see "Every power-on transmits" below. On this rootfs the unit is `fishball-rf-quiesce`, not `S21misc`, which belongs to the Buildroot userspace |
| a TX buffer starts streaming | TX unmuted — your gain if you set one, else the last you used |
| the buffer stops | TX muted and the synthesiser powered down, automatically |

It calls `ad9361_tx_mute()`, ADI's own exported helper, which was already in
the tree but called from nowhere. `patches/0005` exists because restoring the
cached attenuation *unconditionally* turned out to be a trap of its own.
Setting a gain and then starting the stream is the obvious order to do things
in, and the unmute would overwrite that gain a moment later with the previous
transmission's value, so asking for −10 dB could put −60 dB on the wire. The
unmute now restores the cache only if nothing has been set since the mute,
which makes both orders work:

| What you do | What you get |
|---|---|
| set a gain, then start the stream | the gain you set |
| start the stream having set nothing | the last gain you used |

If you have a watchdog script polling `buffer/enable` to re-apply a gain, you
no longer need it — and on a board with a power amplifier it is worse than the
problem it solves, because it applies a fixed gain to both channels a second or
two after *any* stream starts, overriding the application silently.

Where to look for one depends on the rootfs, and the difference is a trap in both
directions:

- **Buildroot** — `/mnt/jffs2/autorun.sh` runs at every boot, so a script there
  survives reflashing the kernel, device tree and bitstream, and appears nowhere
  in the firmware source. Check it first.
- **Debian** — *nothing runs `autorun.sh`*. The file can sit there looking live
  and do nothing, so it is not the explanation; `systemctl list-units 'fishball*'`
  and `systemctl --failed` are. `/mnt/jffs2` is still mounted on both, because it
  is in QSPI rather than on the card.

`grep ^ID= /etc/os-release` says which you are on, and
`tools/selftest/sdr_selftest.py --ssh` reports what is in `/mnt/jffs2` **and**
whether anything on that rootfs would run it.

### What happens when a program stops — and what used to be claimed

This page used to say that the mute holds even when things go wrong, because
the IIO core runs the buffer's `postdisable` hook on teardown **even if the
application crashed or was killed**.

**That was not true, and it was measured false.** Kill a program that is
transmitting *from the board itself* and `buffer/enable` stays `1`: the IIO
core never runs `postdisable`, the mute never fires, and the transmitter stays
live with nobody watching. Through a 20 dB loop the port read −46.7 dBFS
against −59.3 dBFS muted — 12.6 dB hotter, with the program confirmed gone.
The full table is in [`tools/IDLE-CASES.md`](../tools/IDLE-CASES.md).

The mistake was keying off an **event**. Closing, crashing and being killed are
events, and an event can be missed.

**What holds now** is a **state**: the driver watches whether the DAC is still
being fed. If no data arrives for 250 ms while the transmitter is on, it mutes. A
state cannot be missed in the way an event can, so this covers a killed program, a
program that stalls without dying, and a buffer that is switched on and never fed at
all — **with one large exception and one limit, both below.** The exception is a
cyclic transmit, which is deliberately not covered and is the mode most tools here
use. The limit is that the watchdog fires once and does not re-arm. Read both before
relying on this.

```bash
# run on the board - how long the DAC may starve before muting, 0 disables
cat /sys/bus/iio/devices/iio:device2/tx_starve_timeout_ms
```

Measured after the change: a killed local transmitter mutes to −89.75 dB in
**0.26–0.27 s** (0.26 on 6.12, 0.27 on 5.15), and a normal close still mutes
exactly as before.

**One deliberate exception: cyclic transmits.** A cyclic transmit hands the
hardware one buffer and it repeats forever without software — outliving the
program that started it is the *purpose* of the feature, so the watchdog leaves
those alone. Because a kill then looks identical to a normal exit, there is a
separate bound — and **this devkit's rootfs arms it at 60 s on every boot**.

`fishball-rf-quiesce` writes it before `iiod` starts, in the same unit that mutes
both attenuators. **And iiod does not start at all unless that unit succeeded**
(`Requires=`, since 2026-09-30): no proven mute, no network SDR service. The board
stays reachable over `usb0` to find out why — see
[`firmware-modern/debian/README.md`](../firmware-modern/debian/README.md#two-units-and-why-they-are-two). The kernel's compiled-in default stays `0`, off, so nothing
changes for anyone else using these patches; arming it is this board's choice, made
where an operator can see and undo it. Measured after a cold boot, with nothing run
by hand: `tx_cyclic_timeout_ms` reads `60000`.

It matters because **every streaming tool in this devkit transmits cyclically**, so
a killed cyclic stream is the ordinary abnormal ending here, not an exotic one.

```bash
# run on the board - check it, change it, or turn it off
cat /sys/bus/iio/devices/iio:device2/tx_cyclic_timeout_ms   # 60000 after boot
echo 10000 > /sys/bus/iio/devices/iio:device2/tx_cyclic_timeout_ms   # this boot only
fw_setenv tx_cyclic_bound 10000    # a different bound, from the next boot on
fw_setenv tx_cyclic_bound 0        # no bound at all, from the next boot on
```

`tx_cyclic_bound` is deliberately a **separate** switch from `tx_quiesce`. They cover
different things — one the attenuators at boot, the other an unattended stream hours
later — and sharing a switch would mean that turning off the boot mute for some
unrelated reason silently unbounded every cyclic transmit as well.

The one tool here that notices the bound is `tools/sample_gpio_clock.py`, which holds
a cyclic stream open until Ctrl-C. Its RF goes quiet after 60 s; its **pins do not**,
because the sample-GPIO nibble never reaches the DAC. It prints the bound when it
starts with a raised gain, so a carrier disappearing after a minute does not read as
a fault.

### Refusing to transmit at all

```bash
# run on the board
echo 1 > /sys/bus/iio/devices/iio:device0/tx_disable
```

A latch that forces maximum attenuation and **cannot be cleared by the debugfs
routes that could previously raise the transmitter** — `initialize`, which
re-applies the device-tree attenuation to both channels, and `bist_tone` mode 1,
which injects a tone at the transmit port and sends it out through the power
amplifier. Both are reachable over port 30431, which has no authentication at
all. Clearing the latch takes a root write to that same sysfs file — so it is not
protection against anything that already has root, and the honest claim is the
narrower one: **debugfs cannot clear it.** It also reads `0` unless somebody sets it,
so it protects nothing by default.

### Refusing to transmit when hot

```bash
# run on the board - millidegrees C; 0 (the default) disables it
echo 60000 > /sys/bus/iio/devices/iio:device0/tx_temp_limit
```

The board has always reported its die temperature and nothing ever acted on it.
Above the limit, requests to *lower* the attenuation are refused; muting is
never blocked, so the failure direction is silence.

This one has a second use, which is how the bug in the next section was proved
fixed with an antenna still connected. Arm it *below* the die temperature and
every request to get louder is refused **and logged**, while muting still works:

```bash
# run on the board - 1 C, so nothing can ever get louder
echo 1000 > /sys/bus/iio/devices/iio:device0/tx_temp_limit
dmesg | tail -1
# ad9361 spi0.0: die at 40.351 C is over the 1.000 C transmit limit - staying muted
```

The question then becomes *"did the driver ask to get louder?"* rather than
*"what came out of the port?"*, which is answerable safely. Confirm the gate is
live with an explicit `-60 dB` write first — a silent log proves nothing if
nothing was armed.

### The unmute had a value of its own, and zero meant full output

The kernel unmute restores the attenuation that was in force before it muted. On
the factory kernel — and on the 6.12 one before
[`firmware-modern/patches/0019`](../firmware-modern/patches/) — that cached value
lived in the struct `ad9361_clear_state()` wipes with `memset`. **Zero
millidecibels of attenuation is full output**, so:

```bash
# run on the board. On an unpatched kernel, with an antenna fitted, do NOT.
echo 1 > /sys/kernel/debug/iio/iio:device0/initialize
# ...then anything at all that opens a transmit buffer...
```

left the transmitter keyed flat out with nobody having asked for it. Measured on
hardware: TX2 read `0.000000 dB` after exactly that sequence, and neither the
application nor the operator had written a gain at any point in that boot.

It is the third safety-relevant field to be moved out of that struct, after the
`tx_disable` latch and the temperature limit above, and the first one where the
consequence was RF rather than a cleared flag. The fix puts it in
`struct ad9361_rf_phy` and seeds it at probe with maximum attenuation, so
"nothing cached yet" means muted rather than loud.

**If you are running the factory kernel, treat a debugfs `initialize` as
something that requires re-muting afterwards**, and read both attenuations back
rather than assuming:

```bash
# run on your HOST
U=ip:192.168.2.1
for c in 0 1; do iio_attr -u $U -c -o ad9361-phy voltage$c hardwaregain; done
```

The TX mute needed no device tree change of its own, as the driver reaches the
phy through the DDS node's existing `clocks` phandle.

### Every power-on transmits, and no software here can stop it

Measured 2026-09-29 with a second receiver (a HackRF One) cabled to each transmit port
through a pad, recording continuously across power cycles — the only way to see this,
because the board's own receiver dies with the board.

**About one second after power is applied, both TX1A and TX2A emit a narrowband burst of
roughly 4 ms at the transmit LO frequency**, around 50 dB above two control bands 1.0 and 3.0 MHz BELOW it - both on the
same side, because at 4 MSPS centred under the LO there is no room above it, so an
event confined to the upper half-band would not be rejected by this test. It saturated the receiver through 20 dB of attenuation, so its strength is
a lower bound rather than a figure: at or above the loudest calibrated point, which was
an equivalent commanded attenuation of −20 dB. Pinning it exactly needs a re-run at
lower receiver gain.

**It is normal, and it is not a bug.** `ad9361_tx_quad_calib()` drives an NCO tone
through the transmit path to correct I/Q imbalance — transmitting is the mechanism, and
the function aborts if the TX LO is powered down. It runs at `ad9361.c:5308`, *before*
`ad9361_set_tx_atten()` applies the device tree's value at `:5326`. Every AD9361 design
does this. What makes it loud here is the PGA-102+ on transmit.

**So there is no software fix, and nothing on this page helps.** `tx_quiesce`, the
affirmation gate, the starve watchdog and the `tx_disable` latch all live in userspace or
later in the driver, and all of them are too late. The mitigation is operational:

> **Do not leave an antenna on a transmit port you do not want radiating when the board
> is powered up.**

The duty cycle is negligible and it is in the 2.4 GHz ISM band, so this is a
"know about it" rather than a licensing problem — but it was undocumented, and the
measurements are in [`IDLE-CASES.md`](../IDLE-CASES.md).

### Opening a transmit buffer is not a neutral act

The section above is about a cached value of *zero*. The ordinary case is quieter
and more surprising: **the unmute restores whatever gain the last stream used, and
it fires on a bare buffer enable, with nothing having asked for output.** Measured
on 2026-09-29, on a board reading fully muted on both channels:

```
before anything                 atten0=-89.750000  LO_pd=1  buf=0
after a bare buffer enable      atten0=-61.500000  LO_pd=0  buf=1
```

A **28.25 dB** raise, performed by the kernel, bounded only by the loudest gain
used since boot. So "I wrote −89.75 dB before streaming" guarantees nothing, and
neither does "this program never sets a gain". Two consequences worth keeping:

- **Write your attenuation *after* the buffer starts, and read it back.** Anything
  written before the enable is what the restore overwrites.
- **Mute *before* you tear the buffer down, never after.** The stream-stop hook
  snapshots whatever attenuation it finds into that cache and only then applies
  maximum, so closing first hands your gain to whoever streams next. Several tools
  in this repo had that backwards, including the selftest, and `tools/tx-guard.sh`'s
  `reap` documents the ordering for the same reason.

A program that means to stay silent while streaming therefore has to *check*, not
assume: read both attenuators immediately after the enable and stop if either
moved. All four of the devkit's streaming tools now do
(`tools/tx_gate.py:assert_quiet_after_enable`), and an unreadable attenuator counts
as a failure rather than as silence.

### The starve watchdog fires once

It does not re-arm. Once it has muted, the driver believes the transmitter is
muted, and data arriving again does not change that — only a fresh buffer enable
does. So after a starve-mute a gain write raises the attenuator and **nothing
re-mutes it**, not the driver and not stream stop:

```
atten0=-30.000000  LO_pd=1  buf=1      (gain written AFTER the watchdog fired)
```

What keeps that port silent is the **powered-down TX LO**, not the attenuator. Never
read `hardwaregain` on its own and conclude anything; read
`out_altvoltage1_TX_LO_powerdown` beside it.

### Raising output needs a human on record

Nothing on this board can tell you what is attached to a transmit port: there is no
directional coupler and no detector on either one. So the devkit does not pretend to
detect it. It records what a person says, **per channel** — channel 0 is TX1A and
channel 1 is TX2A, two separate SMAs — and refuses to raise that channel without it:

```bash
# run from: the repo root
./devkit tx-guard affirm 0        # only after LOOKING at TX1A
./devkit tx-guard check 0         # exit 0 affirmed, 3 not
./devkit tx-guard revoke both     # withdraw, and force maximum attenuation
```

The record lives in the board's `/tmp`, which is tmpfs, so a reboot withdraws it by
construction rather than by policy. `./devkit selftest --loopback`,
`tools/sample_gpio_clock.py` and `tools/modulation-gallery/board.py` all refuse
without it; `./devkit selftest` on its own and `./devkit gpio-check` never command
output, so they are checked rather than gated. **Muting is never gated** — it has to
work when ssh is down.

This raises the floor; it is not a lock. A direct write to
`out_voltageN_hardwaregain` walks past it, and the affirmation is an ordinary file in
world-writable tmpfs that any process can forge — which is worse than the direct
bypass, because it manufactures a false record that a human vouched for a port.
`0016`'s `tx_disable` latch is the one thing *debugfs* cannot clear, but it reads `0`
unless somebody sets it. The measurements behind all of this are in
[`IDLE-CASES.md`](../IDLE-CASES.md).

Measured over a 50 dB attenuated loopback, **the mute costs no output power**:
commanded and applied attenuation matched to 0.01 dB at every point including
0 dB, and received level tracked commanded gain across 40 dB within 1.9 dB.

### A mute you did not read back is not a mute

Four separate scripts here reported "both channels muted" on the strength of a write
that returned. A write to `out_voltageN_hardwaregain` can fail, and the failure was
being swallowed by a `2>/dev/null` or an `except Exception: pass` — so the message
that says the port is quiet was the one place a live port could hide. Every mute in
this repo now writes, reads back, compares against −89.75 dB, and says **TREAT THAT
PORT AS LIVE** when the read-back disagrees. A helper that returns a pass/fail is
only half of it: callers that discard that return value put the silent failure one
level up, which is where four of them were.

Three ordering rules go with it, each one caught costing something real:

- **Trap `HUP`, not just `EXIT INT TERM`.** Board-side scripts are run over ssh, and
  a dropped session delivers `HUP`. A shell that traps the other three dies untrapped
  and leaves whatever it started running. For `tools/tx-idle-cases/dds-tone.sh` that
  is a DDS tone with no DMA buffer, which means neither the stream-stop mute in
  `0004` nor the starve watchdog in `0015` can ever reach it.
- **Install one handler.** `trap` replaces, it does not append. Two `trap … EXIT`
  lines in one script mean only the second ever runs — and in the harness that holds
  TX at −30 dB longest, the one that was lost was the mute.
- **Mute before you tear the buffer down, on the error paths too.** The happy path
  usually gets this right; the aborts are where it is missed, and an abort is when
  the attenuator is raised. See "Opening a transmit buffer is not a neutral act"
  above for what the next program then inherits.

**And a trapped signal does NOT terminate the shell — the handler must `exit`.**
This is the rule that matters most, and adding `HUP` without it is worse than not
trapping at all. The handler runs and then execution **resumes at the next statement**.
Measured: a script with `trap h EXIT INT TERM HUP PIPE QUIT` reaches its own final line
after a `HUP`. In `cases123.sh` that meant the handler muted and revoked, then the next
case opened a TX buffer, and the kernel's cache restore — which revoking *arms*, by
leaving both attenuators at exactly −89.75 — put the port back at the previous stream's
−30 dB with the operator's session already gone. Shape it like this:

```sh
# run on: the board
trap '_quiet_on_exit' EXIT
trap '_quiet_on_exit; trap - EXIT; exit 130' INT
trap '_quiet_on_exit; trap - EXIT; exit 143' TERM HUP PIPE QUIT
```

and mask the signals as the handler's first statement (`trap '' INT TERM HUP PIPE
QUIT`), because with `PIPE` trapped on a dead stdout every remaining `echo` re-enters it.

**`QUIT` is in that list but does not fire under dash.** Measured on this board twice:
dash accepts the trap — it lists in `trap` — and then dies without running it. Keep it
for other shells; do not rely on it here. `INT` is trapped and does fire, but over a
plain `ssh host "sh script"` with no pty, Ctrl-C never reaches the board: the session
drops and the script gets `HUP` and `PIPE` instead.

**`nohup` silently drops the `HUP` arm.** POSIX shells will not install a trap for a
signal that was ignored on entry, and `nohup` ignores `SIGHUP`. A script launched
`nohup … &` therefore has no HUP handler however carefully it was written — observed on
this board, where `dds-tone.sh` was found gone with its DDS scales still at 0.25 and no
exit line in its log. Run it in the foreground, or follow it with an explicit `off`.


One more thing worth saying plainly: the harnesses in `tools/tx-idle-cases/` call
`tx-guard.sh revoke both` on the way out, which removes the affirmation as well as
muting — including after a clean run. **One affirmation covers one run.** A
back-to-back re-run being refused is the design working, not a fault.

> ### A TX→RX loopback without an attenuator will destroy your receiver
>
> The receiver is the fragile end — rated to roughly **+2.5 dBm** — and **this
> board is sold in a variant with a power amplifier on transmit**, which most
> Pluto advice does not account for. The PA is a Mini-Circuits
> [**PGA-102+**](https://www.minicircuits.com/pdfs/PGA-102+.pdf):
>
> | GHz | 0.05 | 0.8 | 2.0 | 3.0 | 4.0 | 6.0 |
> |---|---|---|---|---|---|---|
> | **Gain (dB)** | **17.7** | 15.9 | 14.0 | 12.5 | 11.5 | 10.4 |
>
> with P1dB around **+17.5 dBm**. Plan for **about +19 dBm** flat out, roughly
> **16 dB above what its own receive port survives**. That figure is the
> self-test's estimate, scaled up from a quieter measurement and stopped at the
> amplifier's compression point; nobody has put a power meter on the port.
>
> <sub>This table and these figures are the canonical copy; `tools/selftest/README.md`
> and the agent skill point here. Update them here first.</sub>
>
> **Fit at least 20 dB of attenuation** in any loopback. More is safe too, but
> for *measuring* the board, 20 dB is also the best choice: the board leaks some
> transmit signal straight into its own receiver, and with 50 dB in the cable
> that leak is as strong as the loop above about 1.5 GHz
> ([details](measured-performance.md#the-boards-own-tx-to-rx-leak)). Start
> at maximum attenuation and raise power in steps.
> [`tools/selftest/`](../tools/selftest/README.md) does all of this and never
> transmits with less than 35 dB of its own attenuation. The non-PA variant is 10–18 dB
> quieter — check which you have before relying on that.
