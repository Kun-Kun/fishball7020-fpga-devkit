# TX idle cases — how a stream can end, and what the transmitter does next

Goal D's working record. One row per way a transmit stream can stop, with the
attenuation **read back from sysfs on the board** afterwards — never inferred
from a call returning.

Bench: TX1 → **21 dB** → RX1 (declared 20, measured 21 by
`./devkit selftest --loopback`). RX2 has an 868 MHz antenna. **TX2 has an
antenna and is never keyed here.** Transmit gain capped at **−10 dB** per the
contract: +19 dBm flat out − 10 − 21 ≈ −12 dBm at a port rated +2.5 dBm.

Read back with, on the board:

```bash
# run from: the board (ssh fishball)
cat /sys/bus/iio/devices/iio:device0/out_voltage{0,1}_hardwaregain
```

## Stream-termination paths

| # | how it was induced | TX1 / TX2 after | verdict |
|---|---|---|---|
| 0 | baseline, nothing ever streamed | `-89.750000` / `-89.750000` | quiet |
| 1 | **normal close** — bounded `iio_writedev -s 65536`, exits by itself | `-89.750000` / `-89.750000` | re-muted |
| 2 | **process kill** — `SIGKILL` to `iio_writedev` mid-stream | `-89.750000` / `-89.750000` | re-muted |
| 3 | **starvation** — buffer opened, fed once, then nothing (patch `0015`) | `-89.750000` / `-89.750000` | re-muted |
| 4 | **client vanishes** — writer and its feeder both `SIGKILL`ed, connection never closed | `-89.750000` / `-89.750000` | re-muted |

Every path re-mutes **both** channels. No path was found that leaves the
transmitter un-attenuated.

> ### "Muted afterwards" is worthless unless it was unmuted first
>
> If the transmitter had been at −89.75 dB throughout, every row above would be
> true and would prove nothing. So the middle of a stream was sampled directly:
>
> ```
> before anything                 -89.750000 dB
> after writing -10, no stream    -10.000000 dB
> DURING the stream               -10.000000 dB   <- genuinely live
> after SIGKILL                   -89.750000 dB   both channels
> ```
>
> The transmitter was really keyed at −10 dB with a buffer streaming, and really
> re-muted. The table is about a transmitter that was on.

## Is anything actually radiating when idle? — RETRACTED

**An earlier version of this file reported a leakage measurement here. It was
wrong twice over and is withdrawn. Nothing in this section should be cited.**

**The frequency axis was wrong by 10.24×.** The scripts hard-coded
`RATE=3_000_000` and never *set* the sample rate — they used whatever the board
happened to be at, which was **30 720 000**. So the reported "−474.6 kHz" peak
was really at −4.86 MHz, the search window for the TX carrier looked nowhere
near where one would land, and the DC exclusion swallowed two of the three sweep
points whole. "The strongest signal never moved" was guaranteed by the arithmetic
before any RF was involved.

**And it was hunting a switched-off oscillator.** The premise — that
`ad9361_tx_mute()` leaves the TX LO running — is the *problem patch `0004`
solves*, not the state it leaves. `patches/0004:198` calls
`ad9361_tx_lo_powerdown(phy, true)` on mute, and the live board agrees:

```
$ ssh fishball 'cat /sys/bus/iio/devices/iio:device0/out_altvoltage1_TX_LO_powerdown'
1
```

I read the patch's statement of the problem as its conclusion.

**Two further defects in the same measurement**, either of which alone would
invalidate it:

- The receiver was in **`slow_attack` AGC**, not manual. The driver refuses
  manual gain writes in AGC mode, so the "70 dB" was a readback, not a setting —
  and maximum is 73 dB, not 70. An AGC is in any case the wrong instrument for
  "did the peak move", because it moves gain to hold the peak constant.
- **There was no positive control.** Muted read −42.2 dBFS and unmuted −42.3 dBFS;
  a method that returns the same number for on, off, and not-under-test has not
  been shown to see a transmitter at all. This file's own box says a quiet
  reading proves nothing until the method is shown to see a loud one — and then
  it did not do that.

Redoing it needs: the sample rate **read from the board**, the receiver in
**manual** gain, a positive control that demonstrably sees a known transmission,
and a result stated in **dBm at the port** rather than dBFS, since dBFS says
nothing about what an unterminated SMA would radiate.

## The boot window

**This board does not run Buildroot.** It is Debian 13 with systemd, so
`S21misc` and its `tx_quiesce` — the mechanism patch `0004` adds — do not exist
here at all. The modern rootfs covers the same ground with
`fishball-rf-quiesce.service`, and there are three layers, not one:

| layer | covers | verified |
|---|---|---|
| 1 device tree `adi,tx-attenuation-mdB` | the instant `ad9361_setup()` runs, before any userspace | **live: `89750`** (89.75 dB) read from `/proc/device-tree/axi/spi@e0006000/ad9361-phy@0` |
| 2 `fishball-rf-quiesce.service` | from then until a DMA buffer starts | `Result=success`, journal: *"both transmitters at −89.75 dB"* |
| 3 kernel `0004` / `0015` | unmute on stream start; on stop or starve, re-mute **and power the TX LO down** | the four cases above; `out_altvoltage1_TX_LO_powerdown` reads **1** while idle |

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



## The affirmation gate — WITHDRAWN

A `tools/tx-affirm.sh` was written for this and has been **removed**, for two
reasons.

**It duplicated something better that already existed.** `tools/tx-guard.sh` has
been in this repo since 26 September: per-channel affirmation — which matters
here, because TX1A has a pad on it and TX2A has an **antenna**, and one global
flag cannot tell them apart — a `set-gain` that *refuses* rather than merely
checking, documented exit codes, a `reap` for buffers left enabled with no
owner, and a LIMITS section more honest than the one I wrote. I never looked for
it.

**And the gate it added was bypassable.** It keyed on `sys.stdin.isatty()`, so
anything allocating a pty walks straight through:

```bash
# run from: the repo root - this skipped the gate entirely
script -qec './devkit selftest --loopback --pad 20' /dev/null
```

CI runners, `expect`, tmux and most agent terminals allocate a pty — precisely
the adversary it was written to stop. A gate that looks like protection and is
not is worse than none, so it is gone rather than patched.

**Since then:** `tools/tx-guard.sh` is wired in as `./devkit tx-guard`, pushed
to the board fresh on every call so no stale copy can answer for the current one.
Its documented exit codes propagate, verified without a pipe in the way (a pipe
makes `$?` report `head`, which is how the first attempt at this table reported
`0` for a refusal):

| invocation | exit | meaning |
|---|---|---|
| `set-gain 0 -10`, ch0 unaffirmed | **3** | refused for want of an affirmation |
| `affirm 0` | 0 | recorded |
| `set-gain 0 -10`, ch0 affirmed | 0 | written **and read back** at −10.000000 |
| `set-gain 1 -10`, ch1 unaffirmed | **3** | refused — and ch1 is the antenna port |
| `set-gain 0 5` | 1 | out of range |
| `revoke both` | 0 | both forced back to −89.75, verified |

**Still ungated:** the MCP's `set_tx_gain` (agent-callable, outside this
contract's scope), `tools/sample_gpio_clock.py --tx-gain`, and
`tools/modulation-gallery/board.py`.

## A safety property worth recording

Raising attenuation **does not by itself enable transmission**:

```
idle                        LO_powerdown=1   atten=-89.750000
after set-gain 0 -20        LO_powerdown=1   atten=-20.000000
```

Patch `0004` powers the TX LO down when it mutes, and it comes back up on a DMA
buffer start — not on an attenuation write. So a raised attenuator with no
stream is still a dead oscillator. That is a second, independent layer under the
affirmation gate, and it is why the retracted measurement found nothing: there
was nothing to find.

**The positive control still does not work, so no emission bound is claimed.** A
DDS tone was set up and `scale` read back `0.000000` — nothing was transmitted,
so the null result measures the apparatus, not the board. A valid bound needs a
transmission that is *demonstrably* present first. Not done.

## Status against the contract

Not met, and recorded as such rather than rounded up.

| requirement | state |
|---|---|
| stream-termination paths enumerated and read back | **done** — four induced, though at most three are distinct (see below) |
| transmitter provably silent in every idle condition | **not met** — the only measurement of what radiates was invalid |
| continuous capture across a power cycle | **not done** — impossible on one board |
| no code path raises attenuation without an affirmation | **not met** — one path of at least four, and that one bypassable |
| two consecutive clean adversarial reviews | **not met** — the first found two CRITICAL issues; the count restarts |

Also outstanding from that review: case 4 ("client vanishes") kills the writer,
which closes the socket cleanly — so it is case 2 with an extra signal, not a
dropped connection, and the local-process path that patch `0015` exists for was
never exercised at all. And the harness never read attenuation *during* a stream
in the four cases, which is the discipline this file opens by claiming.
