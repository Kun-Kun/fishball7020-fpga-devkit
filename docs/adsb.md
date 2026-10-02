# Aircraft overhead: ADS-B on 1090 MHz

Airliners and most other aircraft broadcast who and where they are, twice a
second, on **1090 MHz**. This is **ADS-B** (Automatic Dependent Surveillance –
Broadcast). `./devkit adsb` receives those messages with the board, decodes
them on your PC and shows them live: one row per aircraft, with its callsign,
altitude, speed and position, above a log of every message received.

It **only receives**. It sets up one receiver and reads samples from it, and
never opens a transmit buffer, so there is no transmit gate to pass and no
licence question.

## Quick start

1. Put a **1090 MHz antenna** on **RX1A** (or RX2A, then add `--channel 2`).
   Outdoors, or at a window with a view of the sky. Aircraft are line of sight:
   walls and hills cost more range than anything else.
2. Run:

```bash
# run from: the repo root, on your host PC (not the board)
./devkit adsb                  # the antenna on RX1A
./devkit adsb --channel 2      # the antenna on RX2A
```

The first run fetches PyQt6, the window toolkit, into uv's cache (about
100 MB, once). If you don't have [uv](https://docs.astral.sh/uv/), either
`pip install PyQt6 numpy` or use the terminal version, which needs only numpy:

```bash
# run from: the repo root
./devkit adsb --text                     # messages, plus a table every 10 s
./devkit adsb --text --json --seconds 60 # one minute, then the table as JSON
```

## What you see

**The table** has one row per aircraft heard in the last minute; rows turn
grey after 30 s of silence. Click a column header to sort, and tick *Log:
selected aircraft only* to follow one aircraft.

| column | meaning |
|---|---|
| ICAO | the aircraft's permanent 24-bit address, in hex. Unique worldwide |
| Callsign | the flight number (e.g. `KLM1023`), when the aircraft sends one |
| Squawk | the four-digit code air traffic control assigned. Comes in replies to radar, not ADS-B, so not every aircraft shows one |
| Altitude ft | barometric altitude |
| Speed kt, Track ° | ground speed and direction over the ground. Marked `TAS`/`IAS` when the aircraft reports airspeed and heading instead |
| V/S fpm | climb (+) or descent (−), in feet per minute |
| Latitude, Longitude | once two position messages have been paired (below) |
| Msgs | messages received from it |
| Signal dBFS | how strong it arrives: 0 is the receiver's full scale, so −10 is strong and −40 is weak |

**The log** shows every message whose checksum holds:

```
00:38:46.367  -16.6 dBFS  CRC ok  40621D  8D40621D58C382D690C8AC2863A7  ADS-B  position  38000 ft  even  52.2572,3.9194
```

In order: time, signal level, how far to trust it (below), the aircraft's
address, the raw message in hex, and what it says.

## How far each message is trusted

Every message ends in a 24-bit checksum (a CRC). How to read it depends on the
kind of message, and treating them all the same is how decoders fill up with
aircraft that don't exist:

| mark | meaning |
|---|---|
| `CRC ok` | ADS-B (downlink format 17/18) or an all-call reply (DF11): the checksum proves the message intact |
| `fixed1` | ADS-B with exactly one bad bit, which the checksum located and repaired |
| `AP ok ` | a reply to a ground radar (DF0/4/5/16/20/21). Its checksum is mixed with the aircraft's address, so it proves nothing by itself; it is shown only when that address was already heard in a `CRC ok` message in the last minute |

Everything else is dropped and only counted, as *rejected* in the status bar.
Some rejects are normal: noise sometimes looks like the start of a message.

## Positions

To save bits, a position message carries only part of the latitude and
longitude. Aircraft alternate between two encodings, called *even* and *odd*
(the scheme is CPR, Compact Position Reporting). One of each, received within
10 s of each other, gives the position anywhere on Earth. After that, each new
message decodes alone, relative to the last position. So an aircraft's
position appears a second or two after its first position message.

Give your own location and every position message decodes on its own, from the
first one (valid for aircraft within about 300 km):

```bash
# run from: the repo root
./devkit adsb --lat 50.85 --lon 4.35
```

## Settings

| option | what it does | default |
|---|---|---|
| `--channel 1\|2` | which receiver the antenna is on: RX1A or RX2A | 1 |
| `--gain DB` or `agc` | receive gain; live in the window | 55 dB, manual |
| `--min-snr DB` | how far a message's opening pulses must stand above the noise floor | 9 dB |
| `--uri ip:HOST` | the board, when it is not found by itself | found by `tools/board_addr.py` |
| `--record NAME` | also save the raw samples, as [SigMF](capturing-iq.md) | off |
| `--replay FILE` | decode a recording instead of the board; `--fast`, `--loop` | — |

**Gain.** Manual is the default because ADS-B arrives in 120 µs bursts with
silence between, and the AD9361's automatic gain hunts between them. Lower the
gain when aircraft are close or you are near an airport: a message that
overloads the receiver decodes worse than a weak one. Raise it when the log
stays empty and the antenna is good.

**The sample rate is 4 MSPS** (million samples per second). Each half-bit of a
message then lasts exactly two samples, so the demodulator never has to guess.
That is 16 MB/s over the cable, within the [5 MS/s the USB link
carries](sdrpp.md#best-performance-over-usb).

## Recording and replaying

```bash
# run from: the repo root
./devkit adsb --record flight                   # flight.sigmf-data + .sigmf-meta
./devkit adsb --replay flight.sigmf-meta        # no board needed
./devkit adsb --replay flight.sigmf-meta --text --fast
```

At 4 MSPS a recording grows by 16 MB per second. A replay is the way to tell
"the antenna hears nothing" apart from "the decoder misses it": if a recording
of a busy minute decodes nothing, the problem is in the samples.

## When the table stays empty

- **The status bar says `LINK TOO SLOW`.** Fewer samples arrive than the
  receiver produces, and whole messages are lost. On one bench, `fishball.local`
  resolved to an IPv6 link-local address that delivered 1.3–2.5 MS/s, while
  the USB address delivered the full 4. Use `--uri ip:192.168.2.1`, or
  `export BOARD=192.168.2.1`.
- **`rejected` keeps rising but nothing is `CRC ok`.** The receiver hears
  something shaped like a message, but nothing intact. Usually it is noise:
  check the antenna and its cable first, then try a few dB less or more gain.
- **Nothing at all, and the signal never moves.** Check the antenna is on the
  port `--channel` names. Check with `./devkit adsb --record test` for 10 s,
  then look at the recording in any SigMF viewer: aircraft show as short
  spikes well above the noise.
- **"something else holds the receiver".** SDR++, a capture, or the hardware CI
  has the receive buffer. Close it; only one program can stream at a time.
- **Late at night** there are far fewer aircraft. Daytime near any airway
  usually gives several within a minute, with an outdoor antenna.

## How the decoder works

The code is in `tools/adsb/`, in plain Python and numpy:

| file | does |
|---|---|
| `source.py` | sets up the receiver with `iio_attr`, reads every setting back, and streams with `iio_readdev`; or reads a recording |
| `demod.py` | finds messages in the samples |
| `modes.py` | checksums, fields, positions, and the aircraft table |
| `engine.py` | runs the two in threads, so a slow screen never stalls the stream |
| `gui.py`, `adsb.py` | the window, and the command line |

The receiver is tuned to 1090 MHz exactly, so a message arrives as a pattern
of on/off pulses, and only each sample's magnitude matters. Each message
starts with four pulses in a fixed pattern (the *preamble*), then the bits:
each bit is 1 µs, with the pulse in the first half for a 1 and the second half
for a 0. This is called pulse-position modulation. The demodulator scores every
sample as a possible preamble start, at once with numpy. Wherever the four
pulses stand out from the gaps between them, it reads 56 or 112 bits, depending
on the message type in the first five. Blocks of samples overlap by one whole
message, so a message split across two blocks is found once.

`tools/adsb/test_adsb.py` checks all of it with no board and no antenna.
Field values come from an independent decoder (pyModeS), compared across every
altitude and squawk code. The demodulator is checked end to end on synthetic
messages with random carrier phase, a 50 kHz frequency offset, noise, and
arbitrary block cuts.

```bash
# run from: the repo root
python3 tools/adsb/test_adsb.py
```
