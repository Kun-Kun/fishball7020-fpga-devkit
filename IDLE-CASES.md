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

## Is anything actually radiating when idle?

The attenuation read-back answers "what is the chip set to". It does not answer
"is anything coming out", because `ad9361_tx_mute()` drives the **attenuators**
and deliberately leaves the **TX LO running** — patch `0004` says so, and
`tx_quiesce` in `S21misc` repeats it: *"Attenuation ONLY - deliberately not the
TX LO."*

So the LO leak was looked for directly, by tuning the **receiver 500 kHz off the
transmitter** so that any TX carrier lands clear of the receiver's own LO leak at
0 Hz.

| TX state | strongest in-band signal | tracks the TX LO? |
|---|---|---|
| muted, −89.75 dB | −474.6 kHz @ −42.2 dBFS | **no** |
| unmuted, −10 dB | −474.6 kHz @ −42.3 dBFS | **no** |

Swept with TX LO at 900, 901 and 902 MHz against a fixed 899.5 MHz receiver, at
**70 dB RX gain (maximum)**. The strongest signal never moved: it sits at
−474.6 kHz regardless, so it is a fixed artefact — an off-air signal or an RX
spur — and **not** the transmitter.

**Result: no TX LO leakage detectable above roughly −78 dBFS**, muted or
unmuted, through 21 dB of pad at maximum receive gain.

> ### Two traps this measurement walked into first
>
> **Taking the raw spectrum peak measures the receiver, not the transmitter.**
> Every zero-IF receiver leaks its own oscillator to 0 Hz. The first attempt
> read **−0.6 dBFS with the transmitter muted at −89.75 dB** and would have been
> reported as enormous leakage. Blank a guard band around DC, as
> `tools/sigmf-capture.py --verify` does.
>
> **A quiet reading proves nothing until the method is shown to see a loud one.**
> Measuring at the same LO as the transmitter puts the TX carrier on top of the
> receiver's own DC leak, where a muted and a live transmitter read the same.
> Offsetting the receiver and confirming nothing tracks the TX LO is what makes
> the null result mean something.

## The boot window

**This board does not run Buildroot.** It is Debian 13 with systemd, so
`S21misc` and its `tx_quiesce` — the mechanism patch `0004` adds — do not exist
here at all. The modern rootfs covers the same ground with
`fishball-rf-quiesce.service`, and there are three layers, not one:

| layer | covers | verified |
|---|---|---|
| 1 device tree `adi,tx-attenuation-mdB` | the instant `ad9361_setup()` runs, before any userspace | **live: `89750`** (89.75 dB) read from `/proc/device-tree/axi/spi@e0006000/ad9361-phy@0` |
| 2 `fishball-rf-quiesce.service` | from then until a DMA buffer starts | `Result=success`, journal: *"both transmitters at −89.75 dB"* |
| 3 kernel `0004` / `0015` | unmute on stream start, re-mute on stop or starve | the four cases above |

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

## The affirmation gate

`tools/tx-affirm.sh`, wired in as `./devkit tx-affirm`.

Nothing on this board can sense what is on the TX port — no coupler, no
detector — so the gate does not pretend to detect. It records what a person
says, refuses without it, and expires.

| demonstration | result |
|---|---|
| `--check` with nothing on record | **refuses**, exit 1 |
| `--check` after recording | **accepts**, exit 0 |
| record forged to a previous boot id | **refuses** — *"from a previous boot"* |
| `--clear` then `--check` | **refuses**, exit 1 |
| `/run` filesystem type on the board | **`tmpfs`** — a reboot erases it by construction, not by policy |

There is no default and no `--yes`. An absent record is a refusal.

Wired into the path that actually raises attenuation:
`sdr_selftest.py --loopback`. Interactively its existing prompt *is* a person
looking at the port. **Non-interactively `--pad 20` was not** — it is a number
in a command line, and a script, CI or an agent could pass it with the port
open. That path now requires the record:

```
$ ./devkit selftest --loopback --pad 20 </dev/null
--pad was given but no operator affirmation is on record, and
nothing here is interactive, so nobody has said what the TX port
is attached to. This board cannot sense it.          [exit 1, before any RF]

$ ./devkit tx-affirm "20 dB pad TX1->RX1; TX2 antenna, not keyed"
$ ./devkit selftest --loopback --pad 20 </dev/null
32 passed, 1 warnings, 0 failed in 17 s
```

**What it does not cover:** any libiio client can write
`out_voltageN_hardwaregain` directly and nothing here can stop it. This gates
the devkit's own TX-enabling paths. It shrinks the window; it does not close it.
