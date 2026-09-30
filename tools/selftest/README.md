# Is the board still healthy?

A self-test for the Fishball7020 / PlutoSky. It answers one question, *has this
radio been damaged?*, by asking the board questions whose right answers are
known and reporting where the board departs from them.

```bash
# run from: tools/selftest/
./sdr_selftest.py                 # no cable, never transmits
./sdr_selftest.py --loopback      # + the RF tests; TRANSMITS, needs a cable and a pad
```

Python 3.8+ and nothing else. `numpy` is used for the FFT if you have it and a
pure-Python transform if you don't; the results are identical to four decimal
places, which `test_dsp.py` asserts.

The default run needs nothing connected and never transmits. `--loopback` needs
the transmit socket wired to the receive socket through an **attenuator**, and
it asks you how much attenuation is in the cable before it starts:

```
TX1 ---[ 20 dB pad ]--- RX1        (bigger is safe too; 20 dB measures best)
```

**Do not run `--loopback` with an antenna on the TX port.** Most of this
board's range is licensed spectrum, and with the power amplifier it is not a
trivial transmitter.

## Terms

- **Loopback**: the transmit socket cabled to the receive socket, so the board
  listens to itself.
- **Attenuator / pad**: a small inline part that weakens the signal by a fixed
  amount, quoted in decibels. It goes in the loopback because the transmitter is
  far stronger than the receiver can survive. "A 30 dB pad" makes the signal a
  thousand times weaker in power.
- **dB (decibel)**: a ratio, not an amount. 10 dB is ten times the power, 20 dB
  a hundred, 30 dB a thousand. They add, so two 10 dB attenuators make 20 dB.
- **dBFS**: how loud a received signal is relative to the largest the converter
  can represent. Always negative; −20 dBFS is a tenth of full scale.
- **dBc**: how far an unwanted signal sits below the wanted one. Bigger is
  better.
- **Noise floor**: the level of the background hiss. A signal is only useful if
  it is above it.

## What it checks

### Without a cable, and without transmitting

| What it checks | What a failure means |
|---|---|
| Six Zynq supply rails against ±5% | a regulator has drifted or failed |
| Zynq and AD9361 die temperature | thermal path or a part drawing too much |
| **AD9361 digital-interface eye**: all 16×16 clock/data delays with a PRBS running | the LVDS link to the FPGA is marginal: a cracked joint, a degraded driver |
| **AD9361 internal digital loopback**: a tone through both DMAs and back | the FPGA datapath or either DMA is dropping data |
| Capture length, I/Q both live, DC offset | a stuck or dead converter |
| RX gain chain response over 70 dB | a front end that no longer amplifies |
| Both receive channels | one channel lost |
| Synthesiser tuning, 70 MHz – 6 GHz | a VCO band that no longer locks |

The two rows in bold use the AD9361's **BIST** (*built-in self test*), a tone
and PRBS (pseudo-random bit sequence) generator inside the chip. They inject a
signal the script already knows at a point it chooses, so a bad result says
*which half of the chain* is at fault rather than just "something is wrong".
They need no cable and no antenna, and they run by default.

They read the chip's debugfs registers through IIOD's `READ` and `WRITE`
commands, which take `DEBUG` as an attribute kind alongside `INPUT` and
`OUTPUT` (the same route `iio_attr -D` uses), so they need no ssh.

The internal loopback check does start the transmit datapath, at maximum
attenuation, with the loop closed inside the chip. The mute depth on this board
is at least 75 dB (every reading hits the noise floor), so nothing usable leaves
the port, but the chain is live rather than powered down.

### With a loopback (this transmits)

| What it checks | What a failure means |
|---|---|
| Loop detected, and the path loss in it | an open connector, or a port that has gone deaf |
| **TX attenuator linearity** over 25 dB | compression, or a damaged output stage |
| **RX gain linearity** over 40 dB | a damaged gain stage |
| **Image rejection** | quadrature calibration, or an unbalanced mixer |
| **Harmonic distortion**, 2nd and 3rd | a non-linear output stage |
| **Path loss at 8 frequencies, 100 MHz – 5 GHz** | a band-specific hole: a blown balun or matching network |
| **How far the transmitter actually falls when stopped** | something is leaving the radio keyed |

The sweep is set with `--sweep-points`, `--sweep-start` and `--sweep-stop`; the
loop tests run at `--centre` (default 900 MHz).

## Reading the output

```
== RF loopback ==
  PASS   loopback detected
         tone 68.3 dB above the floor at 900.0 MHz; TX attenuation 20 dB, RX gain 34 dB
  info   external attenuation in the loop
         about 30 dB (+/-3 dB). System gain -25.4 dB.
  PASS   image rejection
         48.2 dBc (image at -250 kHz is -70.4 dBFS)
```

Each line is `PASS`, `WARN`, `FAIL` or `info`. The run ends with a count and
one verdict:

| verdict | meaning | exit status |
|---|---|---|
| `HEALTHY` | nothing failed and nothing warned | 0 |
| `WORKING, with warnings worth reading` | nothing failed; read each `WARN` | 0 |
| `FAULT - see the failures above` | at least one check failed | 1 |
| `cannot reach the board at …` | the script never got as far as testing | 2 |

A run without `--loopback` also prints
`(analogue front end untested - rerun with --loopback)`: a `HEALTHY` from the
default run covers the digital side only.

"System gain" is the loop's transfer function with both programmable gains
divided out, so it describes the cable and the radio's analogue path and
nothing else. That makes it comparable between frequencies and between runs
months apart. The implied pad is derived from it using nominal figures for this
board, so treat it as ±3 dB: enough to tell a 20 dB pad from a 50 dB one, or
from a bare cable, which is all it is for.

`--json FILE` writes the full results.

## Safety

**This cannot overdrive your receiver, even if you forget the attenuator.**

The receiver is the fragile end: the AD9361's RX input is rated to about
**+2.5 dBm**. This board is sold in a variant with a **power amplifier** on
transmit, a Mini-Circuits [PGA-102+](https://www.minicircuits.com/pdfs/PGA-102+.pdf)
whose gain runs from **17.7 dB at 50 MHz down to 10.4 dB at 6 GHz** (full table
in [Transmitter safety](../../docs/transmitter-safety.md), which is the
canonical copy). P1dB is about +17.5 dBm, and flat out the board should be
taken to deliver **about +19 dBm**, about **16 dB above what its own receive
port survives**. That figure is this script's estimate, scaled up from a quieter
measurement and stopped at the amplifier's compression point, not a power meter
reading. Sizing a loopback for a bare AD9361, as most Pluto advice does, gets
this dangerously wrong.

So the script never transmits with less than **35 dB** of its own attenuation:

| | TX output | At RX with **no** pad | With a 50 dB pad |
|---|---|---|---|
| Script's floor, at its −6 dBFS drive | −16 dBm | **−16 dBm** | −66 dBm |
| Same floor, at full-scale drive | −10 dBm | −10 dBm | −60 dBm |
| Damage threshold | | **+2.5 dBm** | |

That is 12.5 dB of margin in the worst case that can be constructed: full
scale, highest PA gain, two ports joined by a barrel. Sweeps *start* at 50 dB,
measure the loop, and only then work downward toward the floor. A 25 dB span is
enough to prove the gain chain is linear, so there is nothing to gain from going
louder. `--min-tx-atten` can lower the floor and prints the resulting power
budget.

**Use a single 20 dB pad for measuring.** Larger pads are just as safe, but the
board leaks a little transmit signal straight into its own receiver, and the
weaker the cable loop, the more that leak distorts the result. With 50 dB on
channel 0, above about 1.5 GHz the leak is as strong as the loop and the
frequency response reads up to 13 dB wrong. Through 20 dB it stays within about
±2 dB. See
[docs/measured-performance.md](../../docs/measured-performance.md#the-boards-own-tx-to-rx-leak).

**It asks how much attenuation is in your cable** (or takes `--pad DB`), then
checks your answer against what it measures and warns if the two disagree by
more than 8 dB. A pad that is missing, is the wrong value, or is not making
contact is the failure that destroys receivers.

The same comparison identifies the board variant: the PA and non-PA variants
differ by exactly the PA's gain, so a pad you are confident about tells the
script which one you have, and it reports that. For example, a declared 50 dB
pad reads back as 51 dB against the PA model and 35 dB against the bare-AD9361
one, which settles it.

Other guarantees:

- **Nothing transmits without `--loopback`.** The default run never keys the
  radio at all.
- Every setting is saved at the start and restored at the end, including after
  Ctrl-C or an exception. The transmitter is muted *before* anything else is
  put back.
- The receiver is held around −22 dBFS and backed off if it approaches full
  scale, so measurements are never taken in compression.
- Every measurement reads back the gain and attenuation actually in force and
  re-asserts them if they have moved, so a setting that changes underneath the
  test is corrected and reported rather than silently corrupting a number.

## Both channels

The board has two transmit and two receive ports. `--channel both` measures
pair 0, then asks you to move the loopback to TX2/RX2 and press Enter:

```bash
# run from: tools/selftest/
./sdr_selftest.py --ssh --loopback --pad 20 --channel both
```

With one set of attenuators you can only test one pair at a time, which is why
it prompts. `--channel 1` runs just the second pair.

## Baselines

Some things have absolute answers: a supply rail is in spec or it is not, and a
gain slope that should be 1.00 dB/dB either is or is not. Those pass or fail on
their own.

Path loss does not. It depends on your cable and your attenuator, and on this
board also on a small leak from each transmitter straight into its own
receiver, which adds a fixed pattern that differs for every pad. So there is no
universal number to compare against. Record a baseline while the board is known
good:

```bash
# run from: tools/selftest/
./sdr_selftest.py --loopback --ssh --save-baseline ~/board-healthy.json
```

and compare against it whenever you suspect something:

```bash
# run from: tools/selftest/
./sdr_selftest.py --loopback --ssh --baseline ~/board-healthy.json
```

That turns *"is 41.6 dB of loss at 2.4 GHz correct?"*, which has no answer, into
*"it was 41.5 dB in March"*, which is the question you wanted. Use the same
cable and pad both times, or the comparison means nothing. `--save-baseline`
merges into an existing file, so a two-channel baseline can be built from two
runs, one per cabled pair.

## When the attenuator moves on its own

If a run reports *"settings changed on their own"*, look at `/mnt/jffs2`
before you suspect your board.

That partition is the one writable, persistent thing on a Pluto, and
`/mnt/jffs2/autorun.sh` runs at every boot **on the Buildroot rootfs** (on
Debian nothing runs it, and the self-test says so). Anything started from there
survives reflashing the kernel, the device tree and the bitstream, and appears
nowhere in the firmware source. A common helper watches the transmit buffer and
applies a working gain shortly after a stream starts:

```sh
# on the board: an example of what such a script contains - not something to run
ACTIVE_GAIN="-10.000000"
# on buffer/enable 0 -> 1:  sleep 2; iio_attr -o -c ad9361-phy voltage0 hardwaregain $ACTIVE_GAIN
# on buffer/enable 1 -> 0:  iio_attr ... hardwaregain -89.750000
```

It fires once per stream, only while streaming, a couple of seconds after the
fact, and at a value nothing in the kernel writes. It also **silently overrides
whatever gain your application set**, which matters with the PGA-102+ fitted,
where 10 dB of attenuation is roughly +13 dBm at the SMA against a +2.5 dBm
receive port.

The self-test handles it two ways. Every measurement re-reads the gain and
attenuation, restores them if they have moved, and counts it, so results stay
correct and the interference is reported. And `--ssh` lists `autorun.sh` and
flags any script under `/mnt/jffs2` that writes radio settings, up front:

```
== Board customisation ==
  info   /mnt/jffs2/autorun.sh runs at every boot
         /mnt/jffs2/tx_watchdog.sh &
  WARN   scripts here write radio settings
         /mnt/jffs2/tx_watchdog.sh
```

`--ssh` is needed only for this check, because `/mnt/jffs2` is a filesystem
rather than an IIO attribute. Without `--ssh` it is skipped and everything else
still runs. `--ssh` takes the board's password as an optional value (default
`$BOARD_PASS`, else `analog`).

## Files

| | |
|---|---|
| `sdr_selftest.py` | the test itself |
| `iiod_min.py` | libiio's network protocol over a plain socket, stdlib only |
| `test_dsp.py` | asserts the measurement maths against known signals, no board needed |
| `test_safety.py` | runs the repository's transmitter-safety behaviours, no board needed |
| `test_targets.py` | runs the two-target (factory / modern) build plumbing, no board needed |

`iiod_min.py` is vendored on purpose. When you suspect your board is damaged is
the worst time to discover that your libiio no longer matches the firmware's,
or that a C extension will not build.
