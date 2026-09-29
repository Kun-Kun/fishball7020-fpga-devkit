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

## Not yet covered

- **The boot window.** `adi,tx-attenuation-mdB` brings the chip up at **10 dB**
  attenuation in FDD, and `tx_quiesce` only reaches −89.75 dB once `S21misc`
  runs. The exposure between those two points is real and is not measured here.
  A continuous capture across a power cycle **cannot be taken on one board** —
  the only receiver is on the board that has to reboot. It needs a second
  receiver or a spectrum analyser.
- **The affirmation gate.** Not yet built.
