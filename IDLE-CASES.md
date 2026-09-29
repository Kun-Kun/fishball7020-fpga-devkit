# TX idle cases — how a stream can end, and what the transmitter does next

Goal D's working record. One row per way a transmit stream can stop, with the
attenuation **read back from sysfs on the board** — never inferred from a call
returning — and, in every **measured** row, a read taken **while the stream was
running**, so that "muted afterwards" is a change of state rather than a state it
was already in. Row 0 is a baseline with no stream, and row 6 is cited from the
older file rather than re-measured; both are marked as such in the table.

> There is a second, older file with this name: [`tools/IDLE-CASES.md`](tools/IDLE-CASES.md).
> It is the 2026-09-26/27 record that found and fixed the original defect (a
> killed local client left the transmitter live) and it covers the cyclic cases
> and the debugfs routes, which this file does not repeat. Where the two differ on
> a number, this file is the later measurement.

Bench: TX1 → **20 dB** → RX1, re-measured this session by
`./devkit selftest --loopback --pad 20` — *"declared 20 dB, measured 20 dB"*,
and 21 dB on a second run, which is the same cable inside the test's ±3 dB.
**TX2 WAS keyed**, with its antenna removed and a pad moved onto it — an earlier
version of this header said "TX2 has an antenna and was never keyed here", which is the
opposite of what the body records, on the antenna-fitted port. The termination cases
(rows 1–5) ran at **−30 dB on channel 0 only**; the calibration ladder for the
boot-window work ran at **−55 to −20 dB**, and the TX2 ladder ran on channel 1. All
inside the contract's −10 dB cap: +19 dBm flat out − 30 − 20 ≈ −31 dBm at a port rated
+2.5 dBm.

**The cabling changed several times during this work and changed again afterwards.**
It is now TX1 → 20 dB → RX1 and TX2 → 30 dB → RX2, both verified by the selftest
(declared 20 measured 20; declared 30 measured 30). Do not read the arrangement above
as current — measure it.

Board: Debian 13, Linux 6.12.0-g70fa2c6d3bdd-dirty, 3.071997 MSPS, TX LO 900 MHz.

**The harnesses are in [`tools/tx-idle-cases/`](tools/tx-idle-cases/)** with a
README saying what each one measures and how to run it. They used to live only in
the board's `/tmp`, which meant this table could not be re-run by anyone but its
author on one boot; review called that out. One exception is named there: the
script behind the idle-emission capture is lost, so that measurement alone cannot
currently be reproduced.

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
| 4 | **network drop** — TCP client of iiod, connection black-holed, **no FIN, no RST**, socket left ESTABLISHED | `-30.000000` `LO_pd=0` `buf=1` | `-89.75` / `-89.75` `LO_pd=1` | **1** | kernel starve watchdog |
| 5 | **local process killed** — `SIGKILL`, local backend, no iiod and no socket at all | `-30.000000` `LO_pd=0` `buf=1` | `-89.75` / `-89.75` `LO_pd=1` | **1** | kernel starve watchdog |
| 6 | **cyclic stream killed** — `SIGKILL` on a cyclic transmit | *(not re-measured here)* | **stays live** | 1 | **nothing** — exempt by design |

Paths 1 to 5 end with **both** channels at maximum attenuation and the TX LO
powered down. **Path 6 does not, and it is the one that matters most here.**

A cyclic transmit hands the hardware one buffer and it repeats forever with no
software involvement, so "no data arriving" describes a *healthy* cyclic stream
and the watchdog exempts it deliberately — which makes a `SIGKILL` on a cyclic
transmit indistinguishable from a normal return. `tx_cyclic_timeout_ms` bounds it
and reads **0 (off)** on this board. It is in `tools/IDLE-CASES.md` as cases E and
F, measured there on the *other* userspace (`fw 95aad-dirty`, busybox), which this
file's own premise says is not what this board runs — so it is cited, not claimed,
and it was **not** re-measured on 6.12.

This is not a corner. **All four of this repo's streaming tools use cyclic
buffers** — `board.py transmit(cyclic=True)`, `sample_gpio_clock.py`, the selftest's
`tx_tone`, and `tx-gpio-bitmap-check.py` — so on this bench the cyclic kill is the
*ordinary* abnormal ending, not an exotic one. What stands between it and a live port is each tool
muting in its own cleanup, which a `SIGKILL` skips by definition. Row 6 is why the
silence claim below is not "done".

Timings, and the conditions they were measured under:

| # | time to mute | `tx_starve_timeout_ms` | note |
|---|---|---|---|
| 1 | 2.65 s | 250 (default) | dominated by the remaining bounded samples playing out, not by any latency |
| 2 | 0.07 s | 250 (default) | iiod saw the disconnect and disabled the buffer |
| 3 | 1.95 s | 250 (default) | 250 ms after the 24 MB feed ran out; the rest is the feed |
| 4 | **0.24 s** | 250 (default) | uptime-to-uptime; see the clock note below |
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

### Why case 4 runs over loopback, and what starved three earlier attempts

Case 4's client is a TCP client of iiod on the board's own loopback, not on the
host across Ethernet. That is a real limitation and it is measured, not assumed.
Same rate, same 256 K-sample buffers, same 10 s, no relay in either path:

```
direct over Ethernet from the host    underflows=5  starve_mutes=1
on the board over loopback            underflows=2  starve_mutes=0
```

The **host↔board Ethernet link cannot keep this DAC fed at 3.072 MSPS**, so over
Ethernet the watchdog fires within seconds with nothing wrong and there is never
a healthy stream to drop. Loopback sustains it. The mechanism under test is
iiod's socket lifecycle and the driver's response to it, and loopback exercises
both identically — but the transport is stated rather than glossed, because it is
the one thing about this case that is not the real-world path.

> **An earlier version of this section said "this board cannot keep a network
> transmit stream fed at 3.072 MSPS" and raised `tx_starve_timeout_ms` to 2000 to
> work around it. That was wrong, and the workaround was unnecessary.** The
> bottleneck was `tools/tcp-blackhole.py` itself: at 64 KB per `recv`/`sendall`,
> the per-syscall overhead on this board's Cortex-A9 starved the DAC through the
> relay — which looks exactly like the board being unable to keep up. With 1 MB
> chunks the same test runs at the **default 250 ms**. The 2000 ms run is
> superseded and its number is not quoted here.
>
> This is the third time in this contract that the apparatus produced the
> finding. It is why the relay now counts and prints the bytes it forwarded, and
> why `--chunk` exists and says what it is for.

Three attempts before that measured starvation while reporting a drop, and the
third looked convincing — "muted 0.02 s after the drop" — until the kernel's own
timestamp was compared against the trigger:

```
kernel logged the mute at 12572.776818, drop was at 12572.83 -> -0.053 s
```

Negative: the transmitter had already muted 53 ms *before* the drop, and the
poller was reading a state that was already there. That run is not in the table.
The accepted run has the delta positive, and at the default timeout:

```
drop at /proc/uptime 13793.18 ; poller saw -89.75 at 13793.42   ->  0.24 s
[13793.338563] iio iio:device2: no transmit data for 250 ms - muting the transmitter
```

**Two corrections to how that number used to be presented**, both found by review.

*The clock.* An earlier version subtracted the kernel log's timestamp from a
`/proc/uptime` reading and called the result +0.159 s, and this file's Traps
section asserted the two were the same clock. **They are not.** Measured three
times on this board by writing a marker to `/dev/kmsg` and bracketing it with
`/proc/uptime` reads, printk runs **0.075 to 0.080 s behind**:

```
uptime 14589.190..14589.200   printk 14589.120   offset -0.075 s
uptime 14589.240..14589.250   printk 14589.168   offset -0.077 s
uptime 14589.290..14589.300   printk 14589.215   offset -0.080 s
```

The figure quoted above is therefore uptime-against-uptime, from the poller, and
the kernel line is shown only as corroboration that the watchdog is what fired.

*The criterion.* "Positive means the drop caused it" is too weak, and it was the
harness's stated test. The watchdog is re-armed on every submitted DMA block, so
it fires `timeout` after the **last block**, not after the drop — and the last
block necessarily precedes the drop. So

```
0 < (mute - drop) <= timeout,   and   (mute - drop) = timeout - (drop - last block)
```

A delta *below* the timeout is therefore expected, not suspicious: 0.24 s against
250 ms says the last block went in about 10 ms before the drop, which is what a
healthy stream cut off mid-flight looks like. What actually disqualifies a run is
a delta at or near **zero**, meaning the mute was already pending when the
trigger was pulled. The rejected run corrects to +0.014 s on this basis — the
stream had stalled ~236 ms before the drop — so it is still rejected, and now for
a reason the arithmetic supports.

**The delta is not what carries this case, and should not be asked to.** The
residual timing uncertainty is tens of milliseconds, the same size as the effect
it was once used to adjudicate. What carries it is the state at the mute, none of
which is a stopwatch reading: `buffer/enable` still `1`, all four sockets still
`ESTAB`, the ABORT guard having confirmed `LO_pd=0` and no prior starve message,
and `buf` dropping to `0` only when the sockets were finally closed.

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

**Four tools here open a TX DMA buffer, not three.** `tools/tx-gpio-bitmap-check.py`
(`./devkit gpio-check`) is the fourth; it was missed by the first sweep of this file
because it only ever *writes* maximum attenuation, so a grep for raises did not see
it — but it enables cyclic TX buffers, and a buffer enable is a raise. It never
commands output, so it is not gated; it now runs the same post-enable check as the
others, on **both** channels, and mutes before closing on its abort paths (it used
to close first, which hands the cache the loud value it just refused to run with).

**And the check runs on every enable, not only when a raise is requested.** The gate
used to be asked only when the requested gain was louder than maximum attenuation —
so `sample_gpio_clock.py`'s *default* invocation asked nothing, opened a cyclic
buffer, and its own docstring called that "safe: transmitter muted". This file
measures that exact operation as a 28.25 dB raise. Every buffer enable in all four
tools is now followed by a read of **both** attenuators, which fails on an
unreadable value rather than assuming quiet.

The three tools that do command output, each shown refusing and accepting:

| tool | unaffirmed | affirmed |
|---|---|---|
| `./devkit selftest --loopback --pad 20` | **exit 1**, refused before the RF loopback's buffer (see the note on the internal one) | 32 passed, 0 failed, exit 0 — unchanged |
| `./devkit selftest` (no `--loopback`) | 23 passed, exit 0 — **untouched**, and this is what CI runs | same |
| `tools/sample_gpio_clock.py --tx-gain -30` | **exit 1**, refused before any buffer was opened | mid-run sysfs read: `atten0=-30.000000 LO_pd=0 buf=1`; after exit `-89.75`, `buf=0` |
| `tools/modulation-gallery/board.py` `transmit(..., -30)` | raises `TxGateRefused` before any buffer was opened; `stop()` runs, both channels `-89.75`, `buf=0` | returns `-30.0`, verified over its own IIOD connection |

**"Nothing was raised" is now measured, not assumed, and the first version of this
table was wrong about it.** All four streaming tools used to open their DMA buffer *first*
and consult the gate only when they got round to writing their own attenuation —
and a buffer enable is itself a raise, by up to the loudest gain used since boot,
for however long the gate takes to answer (`time ./devkit tx-guard check 0` →
`real 0m0.836s`). The demonstrations passed only because the cache happened to be
quiet at the time. The gate is now asked **before** the buffer is created in all
three, and the claim is checked by polling the board flat out during each refusal:

```
# run from: the board, while the tool runs on the host
selftest             buffer_ever_enabled=1  LO_ever_powered=YES  loudest_atten_either_channel=-89.750000  unreadable=0
sample_gpio_clock.py buffer_ever_enabled=0  LO_ever_powered=no   loudest_atten_either_channel=-89.750000  unreadable=0
board.py             buffer_ever_enabled=0  LO_ever_powered=YES  loudest_atten_either_channel=-89.750000  unreadable=0
```

> Re-run with the **current** `watch.sh`. An earlier version of this block was
> produced by the watcher as it was *before* the fixes in the same commit that
> claimed them: it read channel 0 only, seeded its running maximum at −89.75 so an
> unreadable channel was indistinguishable from a quiet one, and had no read-failure
> branch at all. Quoting that output as proof of "nothing was raised" was circular.
> These lines come from the watcher that reads **both** channels and reports
> `unreadable` separately.
>
> **`./devkit gpio-check` is absent from this table on purpose.** It never consults
> the gate — it does not command output — so it has no refusal to poll. Its
> protection is the post-enable check, not a refusal, and the earlier version of this
> block labelled a row `gpio` in a way that invited exactly the wrong reading.

**Read the selftest's row carefully: a buffer *was* enabled, and that is by
design.** `./devkit selftest` has an *internal digital loopback* test that closes
the loop inside the AD9361 and sends a tone through both DMAs without it reaching
the port. It opens a TX buffer. Gating that would require an affirmation for
`./devkit selftest`, which is documented as never transmitting and is the command
CI runs, so it is **not gated — it is checked**: immediately after the enable both
attenuators are read, and if the kernel's cache restore has lifted either one, or
if either cannot be read at all, the run mutes both channels and aborts.

> **That check could not fail the run when it was first written, and this file
> claimed it "fails loudly".** It raised `RuntimeError` from inside a
> `try/except Exception` that downgrades anything it catches to a WARN — and a WARN
> exits 0. So the one detector standing in for the gate on the one path that opens a
> TX buffer without an affirmation was invisible to CI, and its message would have
> read `internal digital loopback unavailable: …`, which looks like a missing feature
> rather than a raised transmitter. It now raises `SystemExit`, which is not an
> `Exception` and cannot be swallowed by that handler. It also used to `continue` past
> an unreadable attenuator, reporting it as muted — the same inversion
> `tools/tx-guard.sh` was rewritten to avoid, reproduced in its Python twin. `loudest_atten0`
above is the evidence that it did not, on this board, with the cache holding
maximum. The RF loopback section, which commands real output, is gated and is what
the `exit 1` came from.

`board.py` powers the TX LO up in `configure_tx()` before it reaches the gate,
which is why its row also reads `YES`. That raises no output on its own — the
attenuators never left maximum, as the same line shows — but it is a real
difference from `sample_gpio_clock.py` and is left as it is rather than papered
over.

So the honest form of the claim is: **no code path commands output without an
affirmation, and the one path that enables a buffer without one is verified not to
have raised the attenuators.** That is weaker than "nothing was raised" and it is
what the measurements support.

Two details worth keeping:

- **Quiet is never gated.** Muting must work when ssh is down, when no
  affirmation exists, and in a `finally:` after something has already gone wrong,
  so callers write maximum attenuation over their own connection and do not come
  through the gate for it.
- **Each tool re-reads the value over its own connection.** The gate reaches the
  board over ssh and these tools over libiio; if those ever resolved to different
  boards, the read-back is what catches it.
- **The gate compares its own read-back too, which it did not always.** It used to
  print a *second, uncompared* `cat` of the attenuation as "verified at", and
  `tx_gate.py` returned that number without checking it against what was asked
  for — so exit 0 plus a plausible-looking line was accepted unconditionally. That
  is reachable, not theoretical: the starve watchdog firing between the compare and
  the report leaves `-89.750000` there, and a caller would have been handed it as a
  success. The gate now reports the value it actually compared, and the adapter
  refuses any read-back more than one 0.25 dB step from the request.
- **The gate has a deadline.** Its subprocess calls had none, so a stalled ssh
  blocked the caller indefinitely — and a caller may already hold a DMA buffer,
  which is itself a raise. A timeout is now reported as a failure to reach the
  gate, never as permission.
- **The selftest is gated once per channel per run, not per write.** A loopback
  run raises attenuation dozens of times across the ramp and the linearity sweep.
  The check sits inside `set_tx_atten`, not beside the `--pad` prompt, so a future
  caller cannot reach the attenuator by another route — and `--pad 20` is not an
  affirmation: a number on a command line says what its author believed was in the
  path, not that somebody has just looked at the port.

## The boot window

**This board does not run Buildroot.** It is Debian 13 with systemd, so the
`S21misc` *script* that patch `0004` adds does not exist here. **Its `tx_quiesce`
switch does, though**, and an earlier version of this section said the whole thing was
absent — which would tell a reader that layer 2 has no off switch when it has:

```sh
# /usr/local/sbin/fishball-rf-quiesce, line 26, on the running board
[ "$(fw_printenv -n tx_quiesce 2>/dev/null)" = "0" ] && exit 0
```

So `fw_setenv tx_quiesce 0` disables layer 2 on this rootfs exactly as it does on
Buildroot. It is unset here, so the unit runs. The modern rootfs covers the same ground with `fishball-rf-quiesce.service`,
and there are three layers, not one:

| layer | covers | verified |
|---|---|---|
| 1 device tree `adi,tx-attenuation-mdB` | **not** the instant `ad9361_setup()` runs — see the measured burst below | **live: `89750`** (89.75 dB) read from `/proc/device-tree/axi/spi@e0006000/ad9361-phy@0`, but applied at `ad9361.c:5326`, *after* the TX calibration at `:5308` has already transmitted |
| 2 `fishball-rf-quiesce.service` | from then until a DMA buffer starts | `Result=success`, journal: *"both transmitters at −89.75 dB"* |
| 3 kernel `0004` / `0015` | unmute on stream start; on stop or starve, re-mute **and power the TX LO down** | the six cases above; `out_altvoltage1_TX_LO_powerdown` reads **1** while idle |

Timing this boot, from systemd and the kernel log:

```
ad9361 probe complete            1.688 s   (chip live, device tree already applied)
fishball-rf-quiesce ran         14.664 s -> 14.897 s   Result=success
```

So layer 2 does not begin for **≈13 s** after the chip is alive — and across that
whole gap the transmitter is held at 89.75 dB by **layer 1**, which was the point
of setting it there. Quoted to one figure on purpose: the two numbers come from
different clocks (systemd's `CLOCK_MONOTONIC` and printk, which differ by ~77 ms
here, and more across the early-boot `sched_clock` switchover), so a decimal place
would be spurious. Nothing in the conclusion depends on it — layer 1 covers the
gap whatever its exact length. `adi,tx-attenuation-mdB` is `0x2710` (10 dB, ADI's
default) in the factory tree at `patches/0002:287`; `firmware-modern/dts` raises
it to `89750`. The board runs the latter.

> **The comment inside the deployed `fishball-rf-quiesce` on the running board still
> describes layer 1 as covering "the instant `ad9361_setup()` runs".** The overlay in
> `firmware-modern/debian/overlay/` is corrected, but the board keeps its copy until the
> rootfs is rewritten, so anyone reading the script *on the board* will find the
> retracted sentence. Verified: `grep -c "covers the instant"
> /usr/local/sbin/fishball-rf-quiesce` → `1`.

**No ordering cycle this boot** — the unit's own comment records a boot where
systemd deleted this safety unit to break a dependency cycle and nobody noticed
until the journal was read. Checked explicitly; it did not recur
(`journalctl -b | grep -ci "ordering cycle"` → `0`, and nothing matching
"deleting job" or "breaking ordering cycle").

**Re-confirmed live on the boot this work ran on**, from systemd rather than from
the kernel ring buffer, so it does not depend on anything that can be cleared:

```
$ systemctl show fishball-rf-quiesce.service -p Result       -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestampMonotonic
Result=success
ExecMainStartTimestampMonotonic=14663959
ExecMainExitTimestampMonotonic=14897439
$ journalctl -b -u fishball-rf-quiesce
fishball-rf-quiesce: both transmitters at -89.75 dB
```

> **The `1.688 s` probe figure is re-checkable, and an earlier version of this file
> wrongly said it was not.** The termination cases ran `dmesg -C` between runs, which
> did discard the line from the kernel's ring buffer — but journald had already
> captured it, and it preserves the **kernel's own** timestamp separately from its
> own receipt time:
>
> ```
> $ journalctl -k -b 0 -o export | grep -B40 "successfully initialized" \
>       | grep -E "^_SOURCE_MONOTONIC_TIMESTAMP|^__MONOTONIC_TIMESTAMP"
> __MONOTONIC_TIMESTAMP=9021648          <- journald's receipt time
> _SOURCE_MONOTONIC_TIMESTAMP=1688130    <- the kernel's printk timestamp: 1.688130 s
> ```
>
> So the figure stands, from this boot, re-read after the fact. The earlier version
> of this block said it "cannot be re-checked", called it "a printk timestamp that no
> longer exists to re-read", said re-establishing it "needs a reboot", and marked it
> **Not done** — all four wrong, and wrong in the direction of claiming a hole in my
> own evidence that was not there. Review found it with one command.
>
> The trap it half-identified is real and worth keeping: `-o short-monotonic` prints
> `__MONOTONIC_TIMESTAMP`, journald's arrival time, which is `9.021648` here because
> journald did not start until 8.003 s and restamped everything it slurped. Anyone
> checking casually finds `9.02`, disagrees with this file by 7.3 s, and is right to
> distrust it until told which field to read.

### The capture was taken, and the boot window is NOT quiet

A HackRF One was cabled to TX1 through the same 20 dB pad and recorded
continuously across power cycles. This is the measurement the contract asks for,
and it took a second receiver because the board's own receiver dies with the board.

**It found a transmission.** Every power-on produces a short, strong, narrowband
burst at the transmitter's LO frequency, about **1 second after power is applied**:

| power cycle | when | duration | peak | above both control bands |
|---|---|---|---|---|
| first | t = 107.026 s | 8 blocks ≈ **4.1 ms** | ≥ ceiling | **+50.5 dB** |
| second | t = 155.054 s | 7 blocks ≈ **3.6 ms** | ≥ ceiling | **+50.9 dB** |

Durations are whole multiples of the analyser's 0.512 ms block, so they carry ±0.5 ms
and the TX1-vs-TX2 "difference" is one block — not a real difference. The second burst
is 1.05 s after
that boot (power-on at t = 154 s, from the board's own `/proc/uptime` read
afterwards). Nothing else in 210 s of recording exceeds either control band by
more than a few dB, and the board-unpowered stretches of the same recording are
the zero reference.

**It is the transmitter, not a power-on click.** A broadband switching transient
would lift every band together. Measured in 5 ms steps with the DC offset removed,
against two control bands 2 MHz away:

```
     t(s)       TX 2400.00   ctl 2397.00   ctl 2399.00
  106.389         -83.2         -82.6         -83.0      quiet
  106.394         -19.1         -70.3         -70.6      NARROWBAND at the TX LO
  106.398         -13.1         -63.9         -62.9      NARROWBAND at the TX LO
  106.403         -83.1         -82.1         -82.6      quiet
```

**How strong.** Calibrated against deliberate transmissions through the same cable
and pad, measured with the identical method, so the pad's value cancels out:

```
  atten -55 dB -> -48.0 dBFS      atten -25 dB -> -18.1 dBFS
  atten -45 dB -> -38.2 dBFS      atten -20 dB -> -13.0 dBFS   (max|sample| 88, no clipping)
  atten -35 dB -> -28.1 dBFS
  fit: dBFS = 1.0007 x atten + 6.95, worst residual 0.11 dB over 35 dB
```

> ### The +8 dBm figure is withdrawn, and so are the 0.3/0.4 dB agreements
>
> An earlier version mapped the burst's −4.1 dBFS through the fit above to an
> equivalent attenuation of −11.0 dB and quoted **≈ +8 dBm at the SMA**. Three things
> are wrong with that and review found all three:
>
> **−4.1 dBFS is the analyser's clip ceiling, not a level.** Feeding the same
> arithmetic a synthetic tone shows the reading saturates and then does not move:
> amplitude ×2 and ×100 — a 34 dB span — both read −4.39 dBFS with 3072 samples pinned.
> The burst read −4.1/−4.4 dBFS. So the measurement is "at or above the ceiling", and
> the ceiling is where two different signals look identical.
>
> **Therefore the agreement figures mean nothing.** "Reproducible to 0.4 dB across two
> cycles" and "within 0.3 dB between TX1 and TX2" are two saturated readings agreeing
> because saturated readings must agree. They are not evidence of reproducibility, and
> not evidence that the two ports are equally strong.
>
> **And it extrapolated the fit 8.9 dB past its loudest point.** The ladder's top is
> −13.0 dBFS at −20 dB commanded; the burst was mapped at −4.1 dBFS. "Worst residual
> 0.11 dB over 35 dB" certifies interpolation, not that.
>
> **What is supported:** the burst is at least as strong as the loudest *calibrated*
> point, i.e. **at or above an equivalent commanded attenuation of −20 dB**, and its
> true level is unbounded above until someone re-runs the capture at lower receiver
> gain. The qualitative result — a strong narrowband burst at the TX LO on both ports
> at every power-on, ~50 dB above two control bands — does not depend on any of this.

**The mechanism — and it is NOT a bug, which an earlier version of this section got
wrong.** The calibration is normal, necessary AD9361 behaviour:

```
ad9361.c:5308   ret = ad9361_tx_quad_calib(phy, real_rx_bandwidth, real_tx_bandwidth, -1);
ad9361.c:5326   ret = ad9361_set_tx_atten(phy, pd->tx_atten, ...);
```

The TX **quadrature calibration** generates an NCO tone and loops it through the
receiver to measure and correct transmit I/Q imbalance. **Transmitting is the
mechanism, not a side effect** — the function aborts outright if the TX LO is in
powerdown (*"Tx QUAD Cal abort due to TX LO in powerdown"*). It is ADI's reference
code and every AD9361 design runs it at init.

> **An earlier version of this section called this "an ordering problem in the
> driver" and proposed reordering `ad9361_setup()` so the attenuation precedes the
> calibration. That fix is wrong and is withdrawn**: muting first would leave nothing
> to calibrate. There is no software fix. `calib_mode = manual_tx_quad` gates only
> the *re*-calibration at `ad9361.c:5425`; the boot call at `:5308` is unconditional.

What *is* wrong, and is corrected above, is this file's own claim that
`adi,tx-attenuation-mdB` covers "the instant `ad9361_setup()` runs". It covers
everything after `:5326` and nothing before it. `firmware/patches/0011` and the modern
device tree set that constant to maximum, which is why the board is silent *once
booted* — and why three rounds of reasoning from register values concluded, wrongly,
that the boot window was covered too.

**Why it matters on THIS board specifically.** A routine calibration tone would be
unremarkable on a bare AD9361. This board carries a **PGA-102+ power amplifier** on
transmit, so the cal tone leaves the SMA *amplified* — which is how a normal init step
becomes loud enough to saturate a receiver through 20 dB of pad.

> The gain figure to use here is **not** the 15.7 dB measured at 900 MHz, and an earlier
> version of this sentence used it. The burst is at 2.4 GHz, where the PGA-102+
> datasheet table in `docs/transmitter-safety.md` gives ≈14.0 dB at 2.0 GHz and less
> above it — so a 900 MHz number is roughly 2 dB optimistic at the burst's frequency,
> in the *opposite* direction from the clipping bound. `sdr_selftest.py`'s
> `PA_GAIN_DB = 18.0` is labelled "worst case" and is the best case. And per that same
> page, nobody has put a power meter on this port — the provenance for which the idle
> emission's dBm figures were withdrawn. The
finding here is therefore not "the driver has a bug" but "this board's PA makes a
standard calibration audible at the connector, nothing in this repo said so, and no
userspace mechanism can reach it".

### TX2A does it too, and TX2A is the port with an antenna on it

Measured afterwards by moving the 20 dB pad and the receiver from TX1 to TX2 and
repeating the power cycle. The prediction was recorded before the run and it held:

| | TX1A | **TX2A** |
|---|---|---|
| duration | 4.1 ms / 3.6 ms | **4.6 ms** |
| peak | −4.1 dBFS | **−4.4 dBFS** |
| separation from both control bands | +50.5 / +50.9 dB | **+50.7 dB** |

**Those two peaks are not "within 0.3 dB of each other" in any meaningful sense** —
both are at the analyser's clip ceiling, where a 34 dB span of true input reads the
same, so their agreement carries no information about whether the ports are equally
strong. What the pair does establish is that **both ports emit**, at a level that
saturates a receiver through a pad. Both transmit chains are configured on this board — `adi,2rx-2tx-mode-enable` is
present in the live device tree and the DDS core exposes all four `out_voltage0..3`
scan elements — and the calibration covers both, so the emission is not specific to one
port.

> An earlier version cited `register 0x002 = 0xEC` for the state "at that moment", ~1 s
> after power-on. That read necessarily happened later, and getting it needs a debugfs
> write, so it cannot speak to what the chip was doing during the burst. The device tree
> and the TX2A capture carry the claim on their own.

**The consequence for a bench.** TX2A on this board is the port that had an antenna
fitted. So plugging the board in **radiates** a few milliseconds around 2.400 GHz at a
level that saturated the measuring receiver through 20 dB of pad — at or above an equivalent commanded attenuation of −20 dB, and
unbounded above until someone re-runs the capture at lower receiver gain. Every time, before any userspace exists and with no way for an
operator to prevent it short of removing the antenna. That is in the 2.4 GHz ISM
band and the duty cycle is negligible, so this is a "know about it" rather than a
"licence problem" — but it is not something any documentation here mentioned, and
`tx_quiesce`, the affirmation gate and every userspace mechanism in this repo are
all far too late to affect it. And there is **no software fix** — the calibration
must transmit to work. The only mitigation is operational: **do not leave an antenna
on a transmit port you do not want radiating at power-on.**

> Only one of the two power cycles was captured for TX2: the recording was
> truncated at 98 s of an intended 350 s when the host's disk quota filled, and the
> second cycle fell outside it. One clean event on TX2, two on TX1.

### RETRACTED: "board.py does not transmit on TX2"

An earlier version of this section claimed `tools/modulation-gallery/board.py`'s
`transmit(..., pair=1)` does not transmit, and generalised it to **"no TX2 measurement
in this repo that went through `board.py` was ever really transmitting"**. That is
**wrong**, and the generalisation was published without the one grep that falsifies it.

`tools/modulation-gallery/campaign.py` is `CH = 1`, drives `board.py`'s `transmit` on
TX2A at 866.5 MHz, and produced `docs/modulation-gallery.md` — ten waveforms with real
measured EVM, PAPR and occupied bandwidth, received on an independent HackRF. And
`git log -L` shows the `mask_for([2, 3], total)` path is byte-identical since then.

Re-measured, TX via `board.py` and RX via the selftest's capture path on a separate
connection, through the TX2 → 30 dB → RX2 loop:

```
pair=1 @ 866.5 MHz, 4.000 MSPS, atten -16 dB   tone 89.7 dB over the noise floor
pair=1 @ 2400.0 MHz, 3.072 MSPS, atten -30 dB  tone 88.8 dB over the noise floor
```

The second line is the exact configuration the original claim was made under. It
transmits.

**What the original observation was, and why it is not evidence.** With a HackRF on
TX2, a hardware-DDS tone came through strongly while a `board.py` DMA transmit did not.
I could not reproduce that, and there were two confirmed cabling errors that evening —
the loop was on RX2 at one point — so the most likely explanation is instrument or
board state rather than the tool. Either way, one unreproduced observation should never
have become "no TX2 measurement in this repo was ever real" while a published
measurement campaign on that exact code path sat in the repo.

**The TX2 boot-burst measurement is unaffected**: it is a receive measurement of the
board's own power-on emission, and its conducted path to TX2 is established
independently by the DDS ladder tracking attenuation at 1.0 dB/dB over 30 dB.

## Withdrawn: the idle-emission measurement

**This file used to carry a section measuring what the transmitter emits between
streams** — a −56.0 dBFS transmitting reference against a −88.9 dBFS idle capture, a
32.9 dB ratio, and dBm figures derived from it. **It has been withdrawn in full and not
replaced.** Every number in it rested on comparing two captures whose receive gain was
never recorded and whose noise floors differed by 15.6 dB — which is what a gain change
looks like — and the script that produced it is lost, so it cannot be re-run to settle
the question.

An earlier edit removed the section without saying so, while the status table below
still cited its 20.8 dB figure: a number that then existed nowhere in the repo. Review
caught that. Recorded here rather than the reference quietly dropped.

**So there is currently no measurement of idle emission between streams.** The power-on
burst above is a different question, measured a different way. Redoing this one needs
the receive gain written down for every capture, a positive control that demonstrably
sees a transmitter, a result in dBm at the port rather than dBFS, and the peak
identified in a bin rather than left unattributed.

## Status against the contract

| requirement | state |
|---|---|
| stream-termination paths enumerated and read back | **done for the five that mute** — paths 1 to 5, each with a during-stream read-back and the `buf` state at the mute. Path 6, a killed cyclic stream, is enumerated and **stays live**; it is cited from `tools/IDLE-CASES.md` and was not re-measured on this kernel |
| a genuine network drop, distinct from a client being killed | **done** — cases 2 and 4 differ only in whether the FIN arrives, both at the default 250 ms |
| the local-process path `0015` exists for | **done** — case 5, 0.26 s at the default timeout, `buf` still 1 |
| transmitter provably silent in every idle condition | **not met** — silent in paths 1 to 5, but a killed **cyclic** stream stays live by design, and that is the mode all four streaming tools here use; the idle emission between streams has **no surviving measurement at all** — the section that held it was withdrawn in full (see below) and not replaced; and the boot window now has a capture, which found an emission rather than silence |
| continuous capture across a power cycle | **done, and it failed** — a HackRF through the same pad recorded power cycles on **both** transmit ports; each produced ~4 ms at the TX LO about 1 s after power-on, at or above an equivalent commanded attenuation of −20 dB (the receiver
saturated, so no upper bound was established). The contract's "nothing above the noise floor outside deliberate transmissions" is **not** satisfied, on either port |
| no code path raises attenuation without an affirmation | **partly** — the three in-scope host tools are gated and demonstrated; the kernel's cache restore and the out-of-scope paths in item 1 and 4 above are not |
| two consecutive adversarial reviews, no medium-or-above findings | **not met** — see the next section |

## The review loop: six rounds, and why it stopped

Six adversarial review rounds ran against this work. Every finding each round raised
was fixed and the fix verified on the board. **Two consecutive clean rounds were never
achieved**, and the loop was stopped deliberately rather than by reaching that bar.

| round | findings | what they were |
|---|---|---|
| 1 | several | the termination table's first version; retracted measurements |
| 2 | several | the case-4 attempts that measured starvation instead of a drop |
| 3 | several | the gate's fail-open paths |
| 4 | 11 medium | fixed in `73f1247` |
| 5 | 11 | fixed in `26f8fb5` |
| 6 | 3 high, several medium and low | fixed in `329a236` and the commit that follows it |

Rounds 1 to 3 predate the per-round bookkeeping; their counts were not recorded at the
time and "several" is as precise as this table can honestly be. From round 4 on the
count is the one the round itself reported.

Round 6 is the reason to be honest about the trend. Its three HIGH findings were not
subtle regressions in new code; two of them were in code written *in response to
round 5*, and one — a `_tx_affirmed.update({0, 1})` that turned the affirmation gate
into a no-op in both verify scripts, while their README claimed they refuse — was a
gate bypass sitting in the part of the work whose entire purpose is the gate. A sixth
round finding that class of defect is evidence that the rate is not yet converging,
not evidence that the seventh would be clean.

So the honest reading of this row is: the findings are fixed and each fix is
demonstrated, but the contract's own standard for *confidence* — two consecutive
clean rounds — has not been met, and nothing here should be read as if it had.

## Traps for whoever measures here next

Each of these produced a confident wrong answer first.

**Compare the kernel's timestamp against your trigger — but not across clocks.**
A poller that waits for `-89.75` will happily report "muted 0.02 s after the drop"
when the transmitter muted before it. The subtraction is what catches that, and an
earlier version of this file made it wrong twice: it asserted that `dmesg`'s
timestamps and `/proc/uptime` are the same clock (**printk runs 0.075–0.080 s
behind**, measured three times here), and it took "positive" as proof of
causation. The watchdog fires `timeout` after the last submitted DMA block, and
the last block precedes the trigger, so `0 < delta <= timeout` always and a delta
*under* the timeout is the expected result. What disqualifies a run is a delta near
**zero**. Use one clock, and do not ask a tens-of-milliseconds subtraction to carry
a conclusion that the state at the mute — `buffer/enable`, the sockets, `LO_pd` —
carries better.

**A TX stream over the host↔board Ethernet link starves on its own.** At
3.072 MSPS with 256 K-sample buffers it takes one starve mute inside 10 s, with
nothing wrong and no relay in the path; the same test over the board's loopback
takes none. Any test that needs a *healthy* network stream should run its client
on the board, and must check `LO_pd` and `dmesg` before believing the stream was
live rather than trusting that the buffer came up.

**Suspect your own instrument before the board.** A relay copying 64 KB at a time
was itself what starved the DAC, and it produced a clean, plausible, wrong
conclusion — "this board cannot keep a network transmit stream fed" — that
survived into a committed version of this file. 1 MB chunks fixed it. Anything
sitting between the client and the radio is part of the measurement.

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

**A mute that is written but not read back is a message, not a mute.** Four scripts
here reported "both channels muted" on the strength of a write that returned, with
the failure path swallowed by `2>/dev/null` or `except Exception: pass`. The line
that says the port is quiet is exactly where a live port hides. Write, read back,
compare against −89.75, and say **TREAT THAT PORT AS LIVE** when it disagrees — and
then *act on* the pass/fail, because four callers were discarding it, which puts the
same silent failure one level up.

**`trap` replaces; it does not append.** Two `trap … EXIT` lines in one script mean
only the second ever runs. In `cases123.sh` the one that was lost was the mute, in
the harness that holds TX at −30 dB longest.

**Trap `HUP` as well.** These scripts are run over ssh and a dropped session delivers
`SIGHUP`, not `INT`. `dds-tone.sh` trapped `EXIT INT TERM` and would have kept a DDS
tone up through a dropped connection — and it opens no DMA buffer, so neither the
stream-stop mute nor the starve watchdog can end it.

**`$?` inside `then` after `! cmd` is the status of the negation, always 0.** `case4b.sh`
printed "the gate refused the raise (exit 0)" for every refusal, hiding which of the
gate's codes fired. Capture the status before the `if`.

**Put every process you started in the kill list, not just the interesting ones.**
`case4b.sh` tracked its writer and its feeder but not its relay, so an abort left
iiod's socket `ESTABLISHED` — the state this case creates deliberately, left behind
by accident.

**One affirmation covers one run.** Every harness here ends with `revoke both`, which
removes the affirmation as well as muting, including on a clean exit. That is the
right default — a second run is a second chance to have moved a cable — but a
back-to-back re-run then exits 3 at the gate, which looks like a fault unless the
script says so. They now say so.

**Say where your control bands are.** `scan-boot-burst.py`'s two controls are both
*below* the TX band, 1.0 and 3.0 MHz from it, because at 4 MSPS centred 1.5 MHz under
the LO there is no room above it. The README called them "2 MHz away" on either side.
The difference matters: the test rejects a click across the whole span, but an event
confined to the half-band above the LO would not be rejected by it.
