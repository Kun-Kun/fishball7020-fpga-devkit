# The harnesses behind IDLE-CASES.md

Every number in the stream-termination table in
[`../../IDLE-CASES.md`](../../IDLE-CASES.md) came from one of these. They were
written in the board's `/tmp` and would have died with the next reboot, along with
the `dmesg` they cite — which made the table unreproducible by anyone but its
author, on one boot. Adversarial review called that out and it was right.

**They transmit.** Every one of them raises TX on channel 0 and expects TX1 → at
least 20 dB → RX1. They raise it *through the gate*, so each needs an affirmation
on record and refuses without one:

```bash
# run from: the repo root, on the HOST
./devkit tx-guard affirm 0        # only after looking at TX1A
```

## What each one is for

| script | runs on | measures |
|---|---|---|
| `cases123.sh` | the board | cases 1, 2 and 3 — normal close, a network client killed so the FIN *does* arrive, and starvation with the client still alive and holding the buffer |
| `case5.sh` | the board | case 5 — a **local** client `SIGKILL`ed. No iiod, no socket: the path `firmware/patches/0015` exists for |
| `case4b.sh` | the board | case 4 — a genuine network **drop**. Needs `tcp-blackhole.py` and `tx-guard.sh` pushed to `/tmp` (see below) |
| `case4a.sh` | the host | case 4 over real Ethernet. **Expected to ABORT**: the host↔board link cannot keep the DAC fed at 3.072 MSPS, so the watchdog fires before the drop. Kept because that abort is itself the measurement |
| `case4-poller.sh` | the board | waits for a loud→quiet transition and records `buffer/enable`, `LO_pd` and `ss` *at that instant* |
| `watch.sh` | the board | polls flat out for N seconds and reports whether the TX buffer was **ever** enabled and the loudest attenuation seen. This is what proves a refusal raised nothing |

## Running them

```bash
# run from: the repo root, on the HOST
./devkit tx-guard status                     # also pushes tx-guard.sh to the board
./devkit tx-guard affirm 0

# cases 1, 2, 3
scp -O tools/tx-idle-cases/cases123.sh fishball:/tmp/ && ssh fishball 'sh /tmp/cases123.sh'

# case 5
scp -O tools/tx-idle-cases/case5.sh fishball:/tmp/ && ssh fishball 'sh /tmp/case5.sh'

# case 4 - the relay and the poller go too
scp -O tools/tcp-blackhole.py tools/tx-idle-cases/case4{b.sh,-poller.sh} fishball:/tmp/
ssh fishball 'sh /tmp/case4b.sh'

./devkit tx-guard revoke both                # when you are done
```

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

The script behind the **idle-emission capture** (the −56.0 / −88.9 dBFS pair) is
not in this directory. It was written in an earlier session's scratchpad and is
gone; only its output survives, in `IDLE-CASES.md`. That measurement is therefore
the one number in that file that cannot currently be re-run, and it should be
rebuilt from scratch rather than trusted the next time it matters.
