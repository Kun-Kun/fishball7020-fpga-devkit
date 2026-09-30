# The harnesses behind IDLE-CASES.md

Every number in the stream-termination table in
[`../../IDLE-CASES.md`](../../IDLE-CASES.md) came from one of these. They were
written in the board's `/tmp` and would have died with the next reboot, along with
the `dmesg` they cite — which made the table unreproducible by anyone but its
author, on one boot. Adversarial review called that out and it was right.

**They transmit.** Each needs an affirmation on record for the channel it keys and
refuses without one.

**And each takes the channel as a required argument — there is no default.** `0` is
TX1A, `1` is TX2A. A script that picks a transmit port for you because you forgot to
say which is the same class of defect as a gate that defaults to affirmed, and one of
these ports may have an antenna on it. Whichever you name, that port needs at least
20 dB of termination on it before you affirm. `cs8-level.py` and `watch.sh` only
observe and take no channel:

```bash
# run from: the repo root, on the HOST
./devkit tx-guard affirm 0        # only after looking at TX1A
```

**One affirmation covers one run.** Every harness here ends by calling
`tx-guard.sh revoke both`, which mutes *and* removes the affirmation — including on a
clean exit. That is deliberate: a second run means a second chance to have moved a
cable, so it asks again. In practice it means `affirm` before each run, and it means a
back-to-back re-run that exits 3 at the gate is the design working, not a fault. Each
script says so on the way out.

## What each one is for

| script | runs on | channel arg | measures |
|---|---|---|---|
| `cases123.sh` | the board | required | cases 1, 2 and 3 — normal close, a network client killed so the FIN *does* arrive, and starvation with the client still alive and holding the buffer |
| `case5.sh` | the board | required | case 5 — a **local** client `SIGKILL`ed. No iiod, no socket: the path `firmware/patches/0015` exists for |
| `case4b.sh` | the board | required | case 4 — a genuine network **drop**. Needs `tcp-blackhole.py` and `tx-guard.sh` pushed to `/tmp` (see below) |
| `case4a.sh` | the host | required, 5th arg | case 4 over real Ethernet. **Expected to ABORT**: the host↔board link cannot keep the DAC fed at 3.072 MSPS, so the watchdog fires before the drop. Kept because that abort is itself the measurement |
| `case4-poller.sh` | the board | required | waits for a loud→quiet transition and records `buffer/enable`, `LO_pd` and `ss` *at that instant* |
| `watch.sh` | the board | none, watches both | polls flat out for N seconds and reports whether the TX buffer was **ever** enabled and the loudest attenuation on **either** channel, with an explicit `unreadable` flag |
| `dds-tone.sh` | the board | required | drives the FPGA's hardware DDS on one chain, **no DMA buffer at all**. The most dangerous script here — see the warning below |
| `cs8-level.py` | the host | none | a **single-FFT peak**, a floor and `max\|sample\|` with a clipping flag. Good for a strong tone; it reads noise as a carrier 8-16 dB over the median, so **it did not produce the ladder** &mdash; `avg-level.py` did |
| `avg-level.py` | the host | none | the averaged analyser behind the idle-emission campaign: per-bin mean over every FFT in a window, clipped blocks rejected and counted |
| `tone.py` | the host | **required, 3rd arg** | a cyclic tone at a commanded attenuation, through the gate &mdash; the calibration ladder's source |
| `verify-rf-paths.py` | the host | none, does both | TX_LO == RX_LO, and the tone lands where it was sent, at each decimation |
| `verify-decimator.py` | the host | none, does both | anti-alias rejection at the predicted fold frequency |

## Running them

```bash
# run from: the repo root, on the HOST
./devkit tx-guard status                     # also pushes tx-guard.sh to the board

# CH is the transmit channel: 0 = TX1A, 1 = TX2A. Every harness below requires it
# and none of them has a default. Look at that port before you affirm it.
CH=0
./devkit tx-guard affirm $CH

# cases 1, 2, 3
scp -O tools/tx-idle-cases/cases123.sh fishball:/tmp/ && ssh fishball "sh /tmp/cases123.sh $CH"

# case 5
scp -O tools/tx-idle-cases/case5.sh fishball:/tmp/ && ssh fishball "sh /tmp/case5.sh $CH"

# case 4 - the relay and the poller go too
scp -O tools/tcp-blackhole.py tools/tx-idle-cases/case4{b.sh,-poller.sh} fishball:/tmp/
ssh fishball "sh /tmp/case4b.sh $CH"

./devkit tx-guard revoke both                # when you are done
```

> ### `dds-tone.sh` is the one to be careful with
>
> It opens **no DMA buffer**, so neither patch `0004`'s stream-stop mute nor `0015`'s
> starve watchdog can ever reach it — there is no stream to stop and no data to stop
> arriving. It powers the TX LO up by hand and can drive either chain. It therefore gates
> on an affirmation for that channel, traps its own exit to turn the tone off and mute
> both channels, and holds in a loop so the trap is what ends it. Do not simplify that
> away: an earlier version had none of it, and an interrupted run left a tone up with
> nothing in the firmware able to end it.

**The three termination harnesses record, rather than abort on, a cache restore at the
buffer enable.** The enable is itself a raise, and after one of these runs the cache
holds that run's own gain — so aborting made them unusable twice in a row. They print
that it happened, mute, verify the mute, and carry on; three consecutive runs come out
clean. A tool that *intends* silence should abort instead, and that is what
`tx_gate.assert_quiet_after_enable` does.

## Three things that will bite you

**Reap between cases.** A killed client leaves `buffer/enable` at `1` with no
owner, and the *next* client then cannot open it — it fails with
`Open unlocked: -32` before streaming a byte, and the run looks like a result.
`./devkit tx-guard reap` first, and `cases123.sh` and `case4b.sh` assert
`buffer/enable` is `0` before they start.

**Pin the sample rate.** These set it explicitly, because another tool left the
board at 30.72 MSPS once and turned "about 2 seconds of samples" into 0.2 s: the
stream was over before the first read-back and case 1 measured a normal close
while claiming to measure something else.

**`case4b.sh` needs `--chunk` large.** At 64 KB per `recv`/`sendall` the relay
itself starves the DAC on this board's CPU, which looks exactly like the board
being unable to keep up. It passes `--chunk 1048576`; do not lower it.

## Not here

The script behind the **idle-emission capture** is not here, and neither is the
measurement any more: that whole section has been withdrawn from `IDLE-CASES.md`,
because its two captures had unrecorded receive gain and floors 15.6 dB apart. Do not go
looking for the −56.0 / −88.9 dBFS pair — it is gone deliberately, and the withdrawal is
recorded there.

## The boot-window capture, with a second receiver

`scan-boot-burst.py` and `tone.py` are the two that found and calibrated the
power-on emission recorded in `../../IDLE-CASES.md`. They need a **second
receiver** — the board's own dies with the board — and on this bench that was a
HackRF One cabled to TX1 through the same 20 dB pad.

```bash
# run from: the repo root, on the HOST. Tune OFF the board's LO on purpose:
# putting its carrier on the receiver's own DC leak makes present and absent read
# alike, which has already cost this contract one invalid measurement.
hackrf_transfer -r /tmp/cycle.cs8 -f 2398500000 -s 4000000 -n 1400000000   # 350 s
#   ... power-cycle the board once or twice while that runs ...
./tools/tx-idle-cases/scan-boot-burst.py /tmp/cycle.cs8 15
```

`scan-boot-burst.py` compares the TX-LO band against two control bands for every
0.5 ms FFT in the file, and reports only where the TX band wins by the threshold.
That rejects a broadband power-on click instead of reporting it, and it finds a
4 ms event in a 350 s file without being told where to look.

Both controls are on the **same side**: 1.0 MHz and 3.0 MHz *below* the TX band,
not one above and one below. The capture is centred 1.5 MHz under the TX LO at
4 MSPS, so only 0.5 MHz of spectrum sits above the TX band - no room for a control
there. The consequence is worth knowing: the test rejects a click that lifts the
whole span, but an event confined to the half-band above the LO would not be
rejected by it.

To turn dBFS into dBm, run the ladder with the receiver **unchanged** and fit it —
the cable and pad then cancel out of the comparison:

```bash
# run from: the repo root. CH is the transmit channel; affirm it first.
CH=0
for a in -55 -45 -35 -25 -20; do ./tools/tx-idle-cases/tone.py $a 8 $CH & sleep 3
  hackrf_transfer -r /tmp/ref$a.cs8 -f 2398500000 -s 4000000 -n 8000000; wait; done
```

**Check for clipping every time.** The burst pinned the receiver's ADC at full
scale (`max|sample| = 127`), which makes its measured power a lower bound rather
than a measurement. Print `max(abs(samples))` alongside any level you quote, and
re-run at lower receiver gain if it saturates.

## Verifying the RF paths and the decimators

`verify-rf-paths.py` and `verify-decimator.py` check the two things a loopback bench
has to get right before any measurement through it means anything: that the receiver
is tuned where the transmitter is, and that decimation does not move or fold the
signal. Both use the selftest's own `Board` class, whose capture path is the one this
repo trusts — an ad-hoc receive harness written for this gave peak-to-floor of 13 dB
at frequencies matching neither the sent tone, for channels that provably work.

```bash
# run from: the repo root. Needs both loops and an affirmation per channel.
./devkit tx-guard affirm 0 && ./devkit tx-guard affirm 1
./tools/tx-idle-cases/verify-rf-paths.py      # LO equality + decimated rates
./tools/tx-idle-cases/verify-decimator.py     # anti-alias rejection
./devkit tx-guard revoke both
```

Results on 2026-09-29, TX1 → 20 dB → RX1 and TX2 → 30 dB → RX2:

| | TX1 → RX1 | TX2 → RX2 |
|---|---|---|
| TX_LO − RX_LO | **+0.0 Hz** | **+0.0 Hz** |
| tone 300 kHz out, received at | 300.000 kHz, **0.0 Hz error** | 300.000 kHz, **0.0 Hz error** |
| tone through ÷1 and ÷8 | same bin, 0 Hz error | same bin, 0 Hz error |
| anti-alias rejection at the fold frequency | **63.8 dB** | **85.3 dB** |

**Both decimators are in the path.** The AD9361's own FIR reports `Rx: 128,2` — 128
taps, ÷2 — and is enabled (`in_out_voltage_filter_fir_en = 1`). The FPGA channelizer
is the ÷8: the RX device advertises exactly two delivered rates, `3071997` and
`383999`, and you select one by writing `in_voltage_sampling_frequency` on
`cf-ad9361-lpc` — **not** on the phy, which is the converter rate.

**Test the fold frequency, not just the rate.** A decimator that changed the sample
rate and nothing else would pass a naive test. The out-of-band tone goes at 600 kHz
and the question is the level at `((600 + fs/2) mod fs) − fs/2` = −168 kHz, where it
would land if nothing filtered it. Looking for "the strongest peak" instead finds
unrelated residue at some other frequency and reads like rejection when it is not.
