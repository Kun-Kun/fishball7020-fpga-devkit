# TX idle cases — how a stream can end, and what the transmitter does next

Goal D's working record. One row per way a transmit stream can stop, with the
attenuation **read back from sysfs on the board** — never inferred from a call
returning — and, in every row, a read taken **while the stream was running**, so
that "muted afterwards" is a change of state rather than a state it was already
in.

> There is a second, older file with this name: [`tools/IDLE-CASES.md`](tools/IDLE-CASES.md).
> It is the 2026-09-26/27 record that found and fixed the original defect (a
> killed local client left the transmitter live) and it covers the cyclic cases
> and the debugfs routes, which this file does not repeat. Where the two differ on
> a number, this file is the later measurement.

Bench: TX1 → **20 dB** → RX1, re-measured this session by
`./devkit selftest --loopback --pad 20` — *"declared 20 dB, measured 20 dB"*,
and 21 dB on a second run, which is the same cable inside the test's ±3 dB.
RX2 has an 868 MHz antenna. **TX2 has an antenna and was never keyed here.**
Every measurement below ran at **−30 dB** on channel 0 only, well inside the
contract's −10 dB cap: +19 dBm flat out − 30 − 20 ≈ −31 dBm at a port rated
+2.5 dBm.

Board: Debian 13, Linux 6.12.0-g70fa2c6d3bdd-dirty, 3.071997 MSPS, TX LO 900 MHz.

Read back with, on the board:

```bash
# run from: the board (ssh fishball)
cat /sys/bus/iio/devices/iio:device0/out_voltage{0,1}_hardwaregain
cat /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_powerdown
cat /sys/bus/iio/devices/iio:device2/buffer/enable
```

## Stream-termination paths

`LO_pd` is `out_altvoltage1_TX_LO_powerdown` and `buf` is the DMA buffer's
`enable`. **`buf` at the moment of the mute is the load-bearing column**: `1`
means nothing tore the stream down and the kernel's own watchdog did the muting;
`0` means the buffer was disabled and the mute came with the teardown.

| # | how it was induced | during the stream | after | `buf` at mute | what muted it |
|---|---|---|---|---|---|
| 0 | baseline, nothing ever streamed | — | `-89.75` / `-89.75` | — | never unmuted |
| 1 | **normal close** — local `iio_writedev -s 9216000`, exits 0 by itself | `-30.000000` `LO_pd=0` `buf=1` | `-89.75` / `-89.75` `LO_pd=1` | **0** | buffer teardown |
| 2 | **network client killed** — `SIGKILL`, socket closes, FIN delivered | `-30.000000` `LO_pd=0` `buf=1` | `-89.75` / `-89.75` `LO_pd=1` | **0** | iiod's own cleanup |
| 3 | **starvation, client alive** — buffer open, fed 24 MB, then nothing, writer still running | `-30.000000` `LO_pd=0` `buf=1` | `-89.75` / `-89.75` `LO_pd=1` | **1** | kernel starve watchdog |
| 4 | **network drop** — connection black-holed, **no FIN, no RST**, socket left ESTABLISHED | `-30.000000` `LO_pd=0` `buf=1` | `-89.75` / `-89.75` `LO_pd=1` | **1** | kernel starve watchdog |
| 5 | **local process killed** — `SIGKILL`, local backend, no iiod and no socket at all | `-30.000000` `LO_pd=0` `buf=1` | `-89.75` / `-89.75` `LO_pd=1` | **1** | kernel starve watchdog |

Every path ends with **both** channels at maximum attenuation and the TX LO
powered down. No path was found that leaves the transmitter un-attenuated.

Timings, and the conditions they were measured under:

| # | time to mute | `tx_starve_timeout_ms` | note |
|---|---|---|---|
| 1 | 2.65 s | 250 (default) | dominated by the remaining bounded samples playing out, not by any latency |
| 2 | 0.07 s | 250 (default) | iiod saw the disconnect and disabled the buffer |
| 3 | 1.95 s | 250 (default) | 250 ms after the 24 MB feed ran out; the rest is the feed |
| 4 | **+1.926 s** | **2000** (raised — see below) | the kernel's own log timestamp, against the drop |
| 5 | **0.26 s** | 250 (default) | `kill -9` to mute, both processes confirmed gone with `ps` |

### Cases 2 and 4 differ in exactly one variable

This is the pair the earlier version of this file got wrong. It had a row called
"client vanishes" that killed the writer — which **closes the socket**, so the
FIN arrives and iiod tidies up. That is case 2 with an extra signal in front of
it, not a dropped connection, and it was recorded as such.

A genuine drop delivers no FIN and no RST: the peer simply stops hearing
anything. [`tools/tcp-blackhole.py`](tools/tcp-blackhole.py) produces that in
userspace — it relays the connection and, on a sentinel, stops copying bytes
while **holding every socket open**, so from the board's side the client has
vanished mid-stream with the connection still up.

The two runs then differ only in whether the FIN arrives, and they take
different paths to the same place:

```
case 2, FIN delivered      kill -9 -> socket closes -> iiod disables the buffer
                           muted 0.07 s later, buf=0, socket gone from `ss`

case 4, no FIN             black-holed -> iiod notices NOTHING
                           both iiod sockets still ESTAB at and after the mute:
                             ESTAB 127.0.0.1:30431  users:(("iiod",pid=306,fd=12))
                             ESTAB 127.0.0.1:30431  users:(("iiod",pid=306,fd=13))
                           muted by the KERNEL, buf still 1
                           buf went 1 -> 0 only when the sockets were finally closed
```

**This closes a caveat the older file had to leave open.** It recorded case D as
"clean in practice — iiod explicitly disables the buffer after a disconnected
client. Not a kernel guarantee." Case 4 shows the outcome does not depend on
iiod at all: with iiod still holding two ESTABLISHED sockets and the buffer still
enabled, the transmitter muted anyway.

Proof it was a real stream and a real drop, not a connection that had already
failed — the relay counts what it forwarded, because the first attempt at this
case dropped a connection that had died seconds earlier and measured nothing:

```
[…] BLACKHOLED 2 flow(s) - no FIN, no RST; sockets held open;
    forwarded flow1 board->client 0.03 MB, flow2 client->board 2.95 MB
```

### Why case 4 ran at 2000 ms and not the default 250

**Because this board cannot keep a network transmit stream fed at 3.072 MSPS**,
and at the default the watchdog therefore fires *before* there is anything to
drop. Measured, with no drop involved at all: over Ethernet, and over loopback
through the relay, at both 2.5 and 3.072 MSPS, with 32 KB and with 256 K-sample
buffers, the starve watchdog mutes within a few seconds of stream start every
time. Three attempts at this case measured that instead of a drop, and the third
one looked convincing — it reported "muted 0.02 s after the drop" — until the
kernel's own timestamp was compared against the drop:

```
kernel logged the mute at 12572.776818, drop was at 12572.83 -> -0.053 s
```

Negative. The transmitter had already muted 53 ms *before* the drop, and the
poller was reading an existing state. That run is not in the table.

Raising the timeout is the **conservative** direction: it makes the mute harder
to achieve, not easier, so the default protects sooner than what is tabulated.
The accepted run has the delta positive and the kernel agreeing:

```
[12621.066457] iio iio:device2: no transmit data for 2000 ms - muting the transmitter
kernel logged the mute at 12621.066457, drop was at 12619.14 -> +1.926 s
```

Case 5 measures the same watchdog at the **default 250 ms** and gets 0.26 s, so
the default is not left untested — only the *network* variant of it is.

## Three mechanisms, and which cases each one covers

Distinguishing them matters, because only one of the three survives a client
that neither exits nor closes its socket.

| mechanism | fires when | cases | evidence |
|---|---|---|---|
| buffer teardown (`0004`'s postdisable mute) | the buffer is disabled — a normal close, or iiod cleaning up after a disconnect | 1, 2 | `buf=0` at the mute |
| iiod's client cleanup | iiod sees the socket close | 2 | socket gone from `ss`; `buf` 0 |
| kernel starve watchdog (`0015`) | no DMA data for `tx_starve_timeout_ms` | 3, 4, 5 | `buf=1` at the mute, `dmesg` names it |

```
iio iio:device2: no transmit data for 250 ms - muting the transmitter
```

## Two things measured this session that were not known

### A bare buffer enable raises TX output, with nothing affirmed

The kernel caches both channels' attenuation when a stream stops and re-imposes
it when the next buffer is enabled (`0004`, gated by `0005`'s
`ad9361_tx_is_muted()`). The older file describes this and calls it "worth
knowing before you assume a muted board stays muted". It is now **measured**:

```
before anything                 atten0=-89.750000  LO_pd=1  buf=0
after a bare buffer enable      atten0=-61.500000  LO_pd=0  buf=1
```

A **28.25 dB raise**, performed by the kernel, on a board that read fully muted,
with no affirmation on record and nothing having asked for gain. The −61.5 dB
was the last value a previous stream had been at — the loopback selftest's. Had
that previous stream been at −10 dB, opening a buffer would have put roughly
+9 dBm at the SMA.

Two things bound it, and neither is the affirmation gate:

- **It can only restore a value some earlier stream actually used**, so it is
  bounded by the loudest gain used since boot. From a fresh boot the cache is
  seeded at probe (`firmware-modern/patches/0019`, after the memset bug that made
  it restore 0 mdB — full output).
- **Ordering fixes it, and one tool here had the ordering backwards.** The mute
  hook snapshots whatever attenuation it finds and *then* sets maximum, so a tool
  that tears its buffer down before muting hands the cache its own loud value.
  `tools/tx-guard.sh reap` documents this and mutes first;
  `tools/sample_gpio_clock.py` did the opposite in its cleanup and has been
  corrected. Verified afterwards, during a real stream:

```
DURING a stream: atten0=-89.750000 atten1=-89.750000 LO_pd=0 buf=1
```

  The cache now restores silence.

This is **not fixed in the kernel**, and the reason is in "Exposure windows left
open" below.

### The starve watchdog does not re-arm

Once it has fired, the driver considers the transmitter muted, and data resuming
does not undo that — only a fresh buffer enable does. So after a starve-mute:

```
atten0=-30.000000  LO_pd=1  buf=1     (gain written AFTER the watchdog fired)
```

A userspace attenuation write raises the attenuator, the driver does not
re-mute, and stream stop does not re-mute either, because it already believes it
is muted. **What stands in the way is the powered-down LO**, not the attenuator:
`LO_pd=1` means the oscillator is off, so a raised attenuator with no stream is
still a dead transmitter. That is the independent second layer, and this is the
first measurement that shows it carrying the load on its own.

## Raising attenuation does not by itself enable transmission

```
idle                        LO_powerdown=1   atten=-89.750000
after set-gain 0 -20        LO_powerdown=1   atten=-20.000000
```

`0004` powers the TX LO down when it mutes and brings it back on a DMA buffer
start — not on an attenuation write. This is why the retracted leakage
measurement below found nothing: there was nothing to find.

## The affirmation gate — which paths go through it now

There is no antenna detector on this board: no coupler, no detector, on either
transmit port. Nothing here detects anything. `tools/tx-guard.sh` records what a
person says is on a port, **per channel** — channel 0 is TX1A and channel 1 is
TX2A, two separate SMAs, and here one has a pad on it and the other has an
antenna — and refuses to raise that channel without it. The record lives in the
board's `/tmp`, which is tmpfs, so a reboot withdraws it by construction.

`tools/tx_gate.py` is the host-side adapter. It is deliberately **not** a second
gate: it shells out to `./devkit tx-guard`, so there is one implementation of the
rule, one store, and one set of exit codes. An earlier attempt at this shipped a
parallel gate beside `tx-guard.sh`, keyed on `sys.stdin.isatty()`, which
`script -qec` walks straight through; it was deleted rather than patched.

Every demonstration below was run without a pipe in the way, because a pipe makes
`$?` report the last command in it — which is how an earlier round of this table
reported `0` for a refusal.

| invocation | exit | result |
|---|---|---|
| `tx-guard set-gain 0 -30`, unaffirmed | **3** | refused; attenuator still `-89.750000` |
| `tx-guard affirm 0` | 0 | recorded |
| `tx-guard set-gain 0 -30`, affirmed | 0 | written **and read back** at `-30.000000` |
| `tx-guard set-gain 1 -30`, unaffirmed | **3** | refused — and ch1 is the antenna port |
| `tx-guard set-gain 0 5` | 1 | outside `[-89.75, 0]` |
| `tx-guard check 0` unaffirmed / affirmed / revoked | **3** / 0 / **3** | a query for tools that write their own attenuation |
| `tx-guard revoke both` | 0 | both forced to `-89.75`, verified |

And the three host tools that raise TX output, each shown refusing and accepting:

| tool | unaffirmed | affirmed |
|---|---|---|
| `./devkit selftest --loopback --pad 20` | **exit 1**, nothing raised, both channels muted on the way out | 32 passed, 0 failed, exit 0 — unchanged |
| `./devkit selftest` (no `--loopback`) | 23 passed, exit 0 — **untouched**, and this is what CI runs | same |
| `tools/sample_gpio_clock.py --tx-gain -30` | refused, **continues MUTED** at `-89.75` with the GPIO pins still running | mid-run sysfs read: `atten0=-30.000000 LO_pd=0 buf=1`; after exit `-89.75`, `buf=0` |
| `tools/modulation-gallery/board.py` `transmit(..., -30)` | raises `TxGateRefused`, `stop()` runs, both channels `-89.75`, `buf=0` | returns `-30.0`, verified over its own IIOD connection |

Two details worth keeping:

- **Quiet is never gated.** Muting must work when ssh is down, when no
  affirmation exists, and in a `finally:` after something has already gone wrong,
  so callers write maximum attenuation over their own connection and do not come
  through the gate for it.
- **Each tool re-reads the value over its own connection.** The gate reaches the
  board over ssh and these tools over libiio; if those ever resolved to different
  boards, the read-back is what catches it.
- **The selftest is gated once per channel per run, not per write.** A loopback
  run raises attenuation dozens of times across the ramp and the linearity sweep.
  The check sits inside `set_tx_atten`, not beside the `--pad` prompt, so a future
  caller cannot reach the attenuator by another route — and `--pad 20` is not an
  affirmation: a number on a command line says what its author believed was in the
  path, not that somebody has just looked at the port.

## The boot window

**This board does not run Buildroot.** It is Debian 13 with systemd, so `S21misc`
and its `tx_quiesce` — the mechanism patch `0004` adds — do not exist here at
all. The modern rootfs covers the same ground with `fishball-rf-quiesce.service`,
and there are three layers, not one:

| layer | covers | verified |
|---|---|---|
| 1 device tree `adi,tx-attenuation-mdB` | the instant `ad9361_setup()` runs, before any userspace | **live: `89750`** (89.75 dB) read from `/proc/device-tree/axi/spi@e0006000/ad9361-phy@0` |
| 2 `fishball-rf-quiesce.service` | from then until a DMA buffer starts | `Result=success`, journal: *"both transmitters at −89.75 dB"* |
| 3 kernel `0004` / `0015` | unmute on stream start; on stop or starve, re-mute **and power the TX LO down** | the six cases above; `out_altvoltage1_TX_LO_powerdown` reads **1** while idle |

Timing this boot, from systemd and the kernel log:

```
ad9361 probe complete            1.688 s   (chip live, device tree already applied)
fishball-rf-quiesce ran         14.664 s -> 14.897 s   Result=success
```

So layer 2 does not begin for **≈13.0 s** after the chip is alive — and across
that whole gap the transmitter is held at 89.75 dB by **layer 1**, which was the
point of setting it there. `adi,tx-attenuation-mdB` is `0x2710` (10 dB, ADI's
default) in the factory tree at `patches/0002:287`; `firmware-modern/dts` raises
it to `89750`. The board runs the latter.

**No ordering cycle this boot** — the unit's own comment records a boot where
systemd deleted this safety unit to break a dependency cycle and nobody noticed
until the journal was read. Checked explicitly; it did not recur.

> A continuous RX capture across a power cycle was **not** taken, and cannot be
> on one board: the only receiver is on the board that has to reboot. The window
> is bounded by timing and by reading the device tree live instead. Proving what
> actually radiates during those 13 s needs a second receiver.

## Idle emission, with a working positive control

Every assumption here is read back rather than assumed: the sample rate off the
board, the receiver in `manual` (an AGC holds the peak constant, which defeats
the question), and the buffer/LO/attenuator state at the moment of each capture.

| | peak | floor | TX state at capture |
|---|---|---|---|
| **transmitting** a tone at −30 dB | **−56.0 dBFS** | −94.1 dBFS | `buf=1 LO_pd=0 atten=-30.000000` |
| **idle**, muted | **−88.9 dBFS** | −109.7 dBFS | `LO_pd=1 atten=-89.750000` |

**32.9 dB** between them. The method sees a transmitter, so the idle number is a
bound rather than a shrug: **idle emission is at the receiver's own noise**,
32.9 dB below a −30 dB transmission through the same path.

Roughly, and with the assumptions stated: −30 dB attenuation against the
selftest's +19 dBm flat out is ≈ −11 dBm at the port, less the measured pad
≈ −32 dBm at the receiver, seen as −56.0 dBFS. On that scale the idle peak of
−88.9 dBFS is ≈ **−65 dBm at the receive port**, ≈ **−44 dBm at the transmit
port**. Treat those as indicative: the tone landed at −702.5 kHz rather than the
+1.5 kHz predicted, so the frequency mapping is not fully understood and no
precise calibration is claimed. The 32.9 dB **ratio** is the solid number.

> ### Three attempts, and why the first two measured nothing
>
> 1. **Wrong axis.** `RATE` hard-coded to 3 MSPS while the board ran at 30.72.
> 2. **Nothing transmitted.** The gain was set *before* the buffer started, so
>    the kernel's cache restore put it back to −89.75 — `buf=1` with
>    `atten=-89.750000`.
> 3. **Starvation.** Feeding 12.3 MB/s down a pipe to a network `iiod` could not
>    keep up, the DAC starved, and patch `0015` muted it — `buf=1 LO_pd=1`. A
>    **cyclic** buffer fixed it: one buffer looped in hardware, nothing to feed.
>
> Each failure produced a confident, quiet, wrong number. The positive control is
> the only reason any of them were caught. Point 3 is the same limit that forced
> case 4's timeout up, found again from the other direction.

## The retracted leakage measurement

**An earlier version of this file reported a leakage measurement. It was wrong
several times over and is withdrawn. Nothing from it should be cited.** The
frequency axis was wrong by 10.24× (`RATE` hard-coded, never set); it was hunting
an oscillator that `0004` switches off (`out_altvoltage1_TX_LO_powerdown` reads
`1` while idle — the patch's statement of the *problem* was read as its
conclusion); the receiver was in `slow_attack` AGC, where the driver refuses
manual gain writes, so "70 dB" was a readback and not a setting; and there was no
positive control — muted read −42.2 dBFS and unmuted −42.3 dBFS, which is what
the apparatus reads with nothing under test. The section above replaces it.

## Exposure windows left open, and why

1. **The kernel's cache restore raises TX with no affirmation** (measured at
   28.25 dB above silence, above). Not closed here. The restore has callers that
   do not consult `0005`'s gate — `ad9361_dig_interface_timing_analysis()` and
   `ad9361_dig_tune()` in `ad9361_conv.c` — and they are *balanced pairs* whose
   mute half re-caches the current value first, so making the restore apply
   maximum attenuation instead would silently mute a transmitter mid-`dig_tune`.
   That is a kernel behaviour change with a regression path, against a contract
   requiring the existing mute-on-stream-stop behaviour be preserved. The
   defensible fix is a new opt-in sysfs knob, which needs a kernel build and
   flash; the ordering rule (mute before tearing down) closes the reachable half
   of it in userspace and is now applied in both tools here that stream.
2. **A cyclic stream is exempt from the watchdog, on purpose.** The hardware
   repeats one buffer forever, so a killed cyclic transmit is indistinguishable
   from a healthy one. `tx_cyclic_timeout_ms` bounds it and is **0 (off)** by
   default. `tools/sample_gpio_clock.py` uses a cyclic buffer; on `SIGINT` its
   cleanup mutes, but on `SIGKILL` nothing does. Measured in
   `tools/IDLE-CASES.md` as cases E and F; not re-measured here.
3. **The gate is tool-level, not enforcement.** Anything writing
   `out_voltageN_hardwaregain` directly bypasses it, and the affirmation is an
   ordinary file in world-writable tmpfs that any process can forge with `touch` —
   which is worse than the direct bypass, because it manufactures a false record
   that a human vouched for a port. The enforcement that cannot be bypassed is
   `firmware/patches/0016`'s `tx_disable` latch, inside `ad9361_set_tx_atten()`.
4. **Raise paths outside this contract's scope are not gated.** The scope given
   was `firmware/patches/`, `firmware/scripts/` and `tools/`. Outside it:
   `matlab/+fishball/` (`TxSink`, `safeTransmit`, `writedevTx`), the GNU Radio
   examples under `examples/`, and the MCP server's `set_tx_gain` in
   `~/Fishball7020-mcp`. Each is a code path that raises TX output with no
   affirmation on record. Closing them is the same one-line call to
   `tx_gate.require_affirmation`, and needs a scope decision.
5. **The boot window's 13.0 s is bounded by argument, not by a capture** — see
   above. It needs a second receiver.

## Status against the contract

| requirement | state |
|---|---|
| stream-termination paths enumerated and read back | **done** — six paths, each with a during-stream read-back and the `buf` state at the mute |
| a genuine network drop, distinct from a client being killed | **done** — cases 2 and 4 differ only in whether the FIN arrives |
| the local-process path `0015` exists for | **done** — case 5, 0.26 s at the default timeout, `buf` still 1 |
| transmitter provably silent in every idle condition | **partly** — silent in all six termination paths and at idle to a measured bound 32.9 dB under a −30 dB transmission; the boot window is bounded by timing, not by a capture |
| continuous capture across a power cycle | **not done** — impossible on one board, recorded as a limit |
| no code path raises attenuation without an affirmation | **partly** — the three in-scope host tools are gated and demonstrated; the kernel's cache restore and the out-of-scope paths in item 1 and 4 above are not |
| two consecutive adversarial reviews, no medium-or-above findings | see below |

## Traps for whoever measures here next

Each of these produced a confident wrong answer first.

**Compare the kernel's timestamp against your trigger.** A poller that waits for
`-89.75` will happily report "muted 0.02 s after the drop" when the transmitter
muted 53 ms *before* it. `dmesg`'s timestamps and `/proc/uptime` are the same
clock, so the subtraction is available and it is the only thing that established
causation here.

**A network TX stream on this board starves on its own.** At 3.072 MSPS the
starve watchdog fires within seconds with nothing wrong. Any test that needs a
*healthy* network stream must either raise `tx_starve_timeout_ms` or do its work
in the first second or two, and must check `LO_pd` and `dmesg` before believing
the stream was live.

**A killed client leaves the buffer enabled, and the next client cannot open
it.** Case 5 leaves `buf=1` with no owner; the following test then failed with
`Open unlocked: -32` before it streamed a byte, and would have been recorded as a
network-drop result. Run `./devkit tx-guard reap` between cases and assert
`buffer/enable` is `0` before starting.

**`settimeout` on a socket applies to the whole socket.** A 50 ms recv timeout in
one direction of a relay made `sendall` raise `socket.timeout` in the other as
soon as the send buffer filled, tearing the stream down silently. Use `select`
for readiness and leave the socket blocking for sends.

**libiio opens a second socket per buffer.** A one-connection relay passes
`iio_info` and fails every stream, as an unexplained client-side
`Open unlocked: -32`.

**Do not use `sleep` immediately after `kill -9`** on a background job in a shell
whose `sleep` is a builtin: it returns instantly on `SIGCHLD` and you read the
attenuation ~10 ms after the kill, before the mute. Poll `/proc/uptime` instead.
Debian's `/bin/sleep` is external and does not have this problem; busybox's does.

**Pin the sample rate at the top of a harness.** Another tool left the board at
30.72 MSPS, which turned "about 2 seconds of samples" into 0.2 s: the stream was
over before the first read-back, and the case measured a normal close while
claiming to measure something else.
