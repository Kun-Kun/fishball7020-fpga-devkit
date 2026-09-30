# Throughput and modulation quality at high sample rates

How fast samples move between this board and a host, where each limit sits,
and how clean real modulated signals (QPSK, 16-QAM, OFDM and others) are up to
the full 61.44 MSPS. Read it before planning a capture or a transmit stream
above a few MSPS. The self-test's tone measurements of the radio itself are in
[measured-performance.md](measured-performance.md).

The short answer: the limit you meet first is the host link and the board's
CPU, not the radio. To transmit at any rate without the host in the loop, load
the waveform once and let the hardware repeat it:

```bash
# run on your HOST - -c makes the transmit buffer cyclic
iio_writedev -u ip:192.168.129.200 -c -b 262144 -s 262144 \
  cf-ad9361-dds-core-lpc voltage2 voltage3 < waveform.bin
```

Board setup and the rule for transmit attenuation are in
[Reproducing it](#reproducing-it). Raw results:
[`img/data/modulation-throughput.json`](img/data/modulation-throughput.json)
and [`img/data/throughput.json`](img/data/throughput.json).

## The units, first

| Term | What it means |
|---|---|
| **dB** | A ratio on a logarithmic scale. Every 10 dB is a factor of ten in power; 3 dB is roughly double. |
| **dBFS** | Measured against *full scale*, the loudest the receiver can represent before clipping. Always negative. −20 dBFS is a comfortable signal. |
| **dBc** | Measured against the *carrier*, the wanted signal. Says how far **below** it an unwanted signal sits, so a bigger number is cleaner. |
| **MSPS** | Million samples per second. Each sample is an I/Q pair: two signed 16-bit numbers, so **four bytes**. |
| **EVM** | Error Vector Magnitude. How far received symbols land from where they should, as a percentage. The single best summary of link quality: 1% is excellent, 5% usable, above 15% unrecoverable. |
| **PAPR** | Peak-to-average power ratio: how spiky a waveform is. Transmit power is limited by the *peak*, so a spiky signal delivers less average power. |
| **Constellation** | The set of points a modulation uses. QPSK has 4, 16-QAM has 16. |
| **DMA** | Direct memory access: the FPGA block that moves samples between the radio and the board's memory without the CPU. |

## Conditions

Unless a section says otherwise: one board, v1.4 firmware, the board on
**gigabit Ethernet**, and a host with **no wired interface**: every network
figure on this page crossed the host's WiFi (540 Mbit/s) and a router before
reaching the board. A wired gigabit host has not been measured. A cable from
`TX2A` through a **20 dB attenuator** into `RX2A`,
tuned to 900 MHz, transmitting at −30 dB attenuation into a receiver at 20 dB
of manual gain, `iio_readdev` buffer 64 Ksamples. Only channel 1
(`TX2A`/`RX2A`) is cabled; nothing here characterises `TX1A`/`RX1A`.

On-board figures (the capture running on the board itself) involve no network
at all, and say so where they appear.

## The short version

- **The radio runs clean at its full 61.44 MSPS.** QPSK holds **2.17%** EVM and
  16-QAM **2.24%** at the top of its range, across 18 MHz of occupied
  bandwidth.
- **Continuous streaming in both directions breaks above about 5 MSPS.** That
  is a host-streaming limit, not a hardware one, and it disappears when
  transmit is made cyclic.
- **Streaming throughput depends on the buffer size.** At a 64 Ksample buffer
  it saturates near 30 MB/s (about 5 MSPS at four bytes per sample in each
  direction). At a 1 Msample buffer, one receive channel sustains **~45 MB/s /
  11.3 MS/s** and two sustain ~43 MB/s. The EVM figures on this page were all
  taken at 64 Ksamples.
- **On the board, with no network, capture reaches 183–220 MB/s on one
  channel**, depending on run length, close to what the converter produces.
- **Capture is bit-perfect at 5 MSPS.** Above that it picks up a few discrete
  sample drops: 2 to 4 per two million samples, even at 61.44 MSPS.
- **OFDM measures far worse than QPSK** on the same link. That is real, and
  follows from its peak-to-average ratio.

## Where the 5 MSPS ceiling comes from

Streaming samples continuously in both directions makes the host, the network
and the board's CPU carry every sample. QPSK EVM against sample rate:

| Link | 2.5 MSPS | 4 MSPS | 5 MSPS | 7.5 MSPS | 10 MSPS | 15 MSPS |
|---|---|---|---|---|---|---|
| USB gadget | 1.34% | **49.5%** | — | — | — | — |
| Gigabit Ethernet | 3.54% | — | **1.89%** | 67.8% | 76.9% | 93.0% |

Ethernet roughly doubles the usable rate, from about 2.5 to 5 MSPS. It does
**not** give the twelve times the wire suggests, because the wire is not the
constraint: raw capture rises from roughly 10 MB/s over USB to about 31 MB/s
over Ethernet, and stops there.

**What fails above the ceiling.** The transmit DMA starves and substitutes
zeros, so the transmitted waveform is *not the one you generated* and the
symbols break up. An EVM above about 15% here means corruption, not a weak
signal.

### Theoretical rates, every RX/TX combination

What each configuration *demands*, before any real link is considered. One
complex sample is 4 bytes on the host side (12-bit I and Q, each in a 16-bit
container), so the arithmetic is `4 × channels × sample rate`.

| Active channels | At the full 61.44 MS/s | Busiest single direction | Sample rate a gigabit link allows |
|---|---:|---:|---:|
| 1 TX | 245.8 MB/s | 245.8 MB/s | 31.25 MS/s |
| 2 TX | 491.5 MB/s | 491.5 MB/s | 15.62 MS/s |
| 1 RX | 245.8 MB/s | 245.8 MB/s | 31.25 MS/s |
| 2 RX | 491.5 MB/s | 491.5 MB/s | 15.62 MS/s |
| 1 RX + 1 TX | 491.5 MB/s | 245.8 MB/s | 31.25 MS/s |
| 1 RX + 2 TX | 737.3 MB/s | 491.5 MB/s | 15.62 MS/s |
| 2 RX + 1 TX | 737.3 MB/s | 491.5 MB/s | 15.62 MS/s |
| 2 RX + 2 TX | 983.0 MB/s | 491.5 MB/s | 15.62 MS/s |

**Two directions, not one total.** Ethernet is full duplex, so transmit and
receive each get their own 125 MB/s and do not compete *on the wire*. That is
why `1 RX + 1 TX` allows the same 31.25 MS/s as `1 RX` alone, and why the
column that matters for a link is the busiest single direction rather than the
sum. They do still compete for the board's CPU.

#### The chip's own interface

The AD9361 reaches the FPGA over LVDS (low-voltage differential signalling):
**6 differential lanes each direction** (`RX_D0`–`RX_D5`, `TX_D0`–`TX_D5` in
the data sheet's pin list), double data rate, with `DATA_CLK` specified to
245.76 MHz, a 4.069 ns period (data sheet Rev. G).

```
# LVDS port capacity, per direction
6 lanes × 2 (DDR) × 245.76 MHz = 2.949 Gbit/s in each direction
one channel per sample         = 12-bit I + 12-bit Q = 24 bits

  1 channel   2.949 Gbit/s ÷ 24 bits = 122.88 MS/s
  2 channels  2.949 Gbit/s ÷ 48 bits =  61.44 MS/s
```

The second line is exactly the converter's maximum: **the data port is sized
for two channels at full rate and nothing more.** With one channel the port
could carry twice what the converter produces, so the converter is the limit;
with two, the port and the converter run out together.

This board is configured `adi,2rx-2tx-mode-enable`, so both channels occupy
the interface whether or not you read both. Enabling one channel halves the
data reaching your *host*, not the traffic on the LVDS link.

#### Which limit you meet

In practice, in this order:

1. **Your host link.** Usually first, and the only one you can change cheaply.
2. **The board's CPU.** A capture run on the board sustains far more than any
   network figure here (below).
3. **The LVDS port and the converter.** 61.44 MS/s on two channels, reachable
   only by keeping the host out of the loop entirely.

### Throughput against buffer size

`iio_readdev`'s `-b` (buffer size) moves the streaming ceiling by a factor of
three. Conditions: receive only, 33.6 Msamples per run, mean of three runs per
point; the host has no wired interface and reaches the board over WiFi
negotiated at 540 Mbit/s (~68 MB/s at the PHY).

| Buffer | 1 RX channel | 2 RX channels |
|---|---|---|
| 16 Ksamples | 14.9 MB/s | 16.6 MB/s |
| 64 Ksamples | **28.3 MB/s** (the buffer used for the EVM tables) | 28.0 MB/s |
| 256 Ksamples | 39.1 MB/s | 34.7 MB/s |
| 1 Msample | 45.4 MB/s | 44.8 MB/s |
| 2 Msamples | **46.2 MB/s** | 40.0 MB/s |
| 4 Msamples | 44.4 MB/s | 44.9 MB/s |

It plateaus near **44 MB/s** above about 1 Msample. The spread between repeats
reaches 13 MB/s at one point, so do not trust single runs. The ~44 MB/s plateau
is close to what that WiFi path carries once TCP overhead is paid. A wired
gigabit host has not been tested with this sweep.

Figure data: [`img/data/throughput.json`](img/data/throughput.json), plotted by
[`tools/plot_throughput.py`](../tools/plot_throughput.py).

### On the board, with no network

The identical capture run **on the board**:

| | 1 RX channel | 2 RX channels |
|---|---|---|
| On the board | **199 MB/s — 49.8 MS/s** | **369 MB/s — 46.2 MS/s each** |
| Over the network above | 45 MB/s — 11.3 MS/s | 43 MB/s — 5.4 MS/s each |

The board moves four to eight times more than any network figure here, close to
what the converter produces. Locally the buffer size barely matters (216 MB/s
at 64 K against 200 MB/s at 1 M), so the buffer effect above is a round-trip
property of the link, not of the board.

**These local numbers include a fixed startup cost.** `iio_readdev`'s process
start and buffer allocation sit *inside* the timed window, and 33.6 Msamples at
61.44 MS/s is only 0.7 s, so about a sixth of the measurement is fixed cost.
With **four times the samples** (134.4 M), on the same board, the figures rise
to **220 MB/s / 57.7 MS/s** on one channel and **431 MB/s / 56.5 MS/s** on two.
When comparing your own board, use **the same sample count**.

**The kernel makes no difference.** Interleaved 6.12 → 5.15 → 6.12 on one
board, same tool, buffer, sample rate and counts, three repeats each:

| | 33.6 M, 1 ch | 33.6 M, 2 ch | 134.4 M, 1 ch | 134.4 M, 2 ch |
|---|---|---|---|---|
| 6.12 | 183.1 MB/s | 346.4 MB/s | 220.0 MB/s | 430.8 MB/s |
| 5.15 | 183.1 MB/s | 346.4 MB/s | 220.0 MB/s | 430.8 MB/s |
| 6.12 again | 183.1 MB/s | 341.8–346.4 MB/s | 220.0 MB/s | 429.0–430.8 MB/s |

The scatter *within* one kernel (341.8–346.4) is larger than any difference
*between* them.

This A/B table is the reference for on-board throughput. Neither kernel
reproduces the 199 / 369 MB/s of the previous table at 33.6 Msamples (both give
183 / 346), while both exceed it at 134.4 M. That difference is method: the
199 / 369 figures come from earlier firmware and a timing method whose startup
handling is not recorded. Re-run it with
[`tools/throughput-ab.sh`](../tools/throughput-ab.sh), which fixes everything
that can drift.

## Cyclic transmit: let the hardware repeat the waveform

The transmit DMA on this board has `CYCLIC = 1`. Load a buffer once and the
hardware replays it forever with no further help from the host, which frees
the entire link for capture. The `-c` flag in the command at the top of this
page does this.

Same cable and settings as the streaming table above:

| Sample rate | QPSK EVM | 16-QAM EVM | Implied SNR |
|---|---|---|---|
| 5.00 MSPS | 1.76% | 1.61% | ~35 dB |
| 15.00 MSPS | 1.67% | 1.62% | ~36 dB |
| 30.72 MSPS | 2.05% | 2.04% | ~34 dB |
| **61.44 MSPS** | **2.18%** | **2.26%** | ~33 dB |

Clean at every rate: EVM changes by less than half a percentage point across a
**twelve-fold** increase in sample rate.

A cyclic buffer repeats, so it carries no unique data. It suits test signals,
beacons, radar chirps and calibration; it is not a way to send a message.

## The radio itself at full rate

A tone generated *inside the FPGA* removes transmit from the host entirely, so
this measures the radio and the capture path alone. The signal still leaves
`TX2A`, crosses the pad, and returns to `RX2A`.

| Sample rate | Bandwidth | Throughput | Tone SNR | SFDR | Image rejection | Sample drops |
|---|---|---|---|---|---|---|
| 5.00 MSPS | 4.0 MHz | 16.3 MB/s | 90.1 dB | 43.2 dB | 43.2 dB | **0** |
| 15.00 MSPS | 12.0 MHz | 26.3 MB/s | 89.9 dB | 48.2 dB | 65.6 dB | 2 |
| 30.72 MSPS | 24.6 MHz | 31.4 MB/s | 88.1 dB | 46.4 dB | 76.5 dB | 3 |
| 61.44 MSPS | 49.2 MHz | 26.6 MB/s | 85.4 dB | 42.1 dB | 65.9 dB | 4 |

SFDR is spurious-free dynamic range: how far the tone stands above the largest
unwanted line. Tone signal-to-noise falls only **4.7 dB across the whole
sweep**. Image rejection *improves* with rate (43 dB at 5 MSPS, 76 dB at
30.72) because the quadrature calibration works better with the tone further
from centre.

Throughput plateaus near **31 MB/s**. The gigabit wire is not the limit; the
board's CPU moving samples through the network stack is.

### How the drops are detected

De-rotate the capture by the tone frequency and the residual phase should be
constant. A lost chunk of samples shows up as a step. Every step here is
**exactly π**, which at a tone of `fs/8` means a loss of a multiple of four
samples. Between the steps the phase is flat to four decimal places, so these
are discrete dropped packets, not continuous degradation.

The same test with the AD9361's internal BIST tone (built-in self-test,
injected inside the chip on the receive path, no RF at all) gives the identical
picture. So the drops are in the capture and transport path, not in the radio.
[`tools/sigmf-capture.py --verify`](capturing-iq.md) runs this check on any
capture with a dominant tone.

```bash
# run on your HOST - inject a known tone inside the chip, no RF
iio_attr -u ip:192.168.129.200 -D ad9361-phy bist_tone "2 7680000 0 0"
# ... capture ...
iio_attr -u ip:192.168.129.200 -D ad9361-phy bist_tone "0 0 0 0"   # off again
```

## Every waveform at 61.44 MSPS

All seven at the same transmit attenuation, captured across
the full 56 MHz receive bandwidth.

| Waveform | RX rms | PAPR | Occupied BW | Key figure |
|---|---|---|---|---|
| CW tone | −16.74 dBFS | 0.75 dB | 30 kHz | image rejection **71.1 dBc**, LO leak 62.0 dBc, SNR 71.0 dB |
| Two-tone | −19.73 dBFS | 3.56 dB | 4.02 MHz | IMD3 **55.8 dBc** |
| QPSK | −20.66 dBFS | 4.14 dB | 17.96 MHz | EVM **2.17%** |
| 16-QAM | −22.84 dBFS | 6.20 dB | 18.12 MHz | EVM **2.24%** |
| OFDM | −27.90 dBFS | 11.06 dB | 50.19 MHz | EVM 51.2%, see below |
| Band-limited noise | −27.84 dBFS | 11.23 dB | 43.83 MHz | flatness **0.81 dB** std |
| Linear chirp | −17.09 dBFS | 1.14 dB | 39.62 MHz | flatness figure not valid, see [limits](#what-these-numbers-are-not) |

IMD3 is the third-order intermodulation product of the two tones; LO leak is
local-oscillator feedthrough, relative to the tone.

## Why OFDM measures worse

OFDM reads far worse than QPSK on the same link in the same run. The analysis
is sound: run against the *clean transmit file*, the demodulator reads
**0.00%**.

The cause is **peak-to-average ratio**. OFDM is the sum of 52 independent
subcarriers, so it peaks 11.06 dB above its own average against 4.14 dB for
QPSK. Transmit power is limited by the peak, so at the same peak OFDM puts
about **7 dB less average power** on the link; the received levels in the table
above agree, 7.24 dB apart. Same noise floor, less signal.

It is noise, not clipping. Backing the transmit level off in 6 dB steps:

| TX backoff | RX rms | OFDM EVM |
|---|---|---|
| 0 dB | −29.2 dBFS | 13.4% |
| −6 dB | −35.1 dBFS | 19.6% |
| −12 dB | −40.4 dBFS | 28.4% |
| −18 dB | −44.3 dBFS | 38.0% |

EVM gets steadily **worse** as the signal weakens, which is the signature of a
noise-limited link; compression would improve with backoff. It is also not
band-edge filter roll-off (degradation is uniform across subcarriers, only 1.2×
edge-to-centre), not cyclic-prefix length (16 to 128 samples barely moves it),
and not the AD9361's adaptive DC and quadrature tracking loops (switching them
off makes it worse).

OFDM also varies a lot run to run, 13% to 51% at nominally identical settings,
which matches this board's
[spread in transmit quadrature calibration](measured-performance.md#transmit-chain).

## Pitfalls when measuring EVM

- **A 45° constellation rotation makes good data look terrible.** Estimating
  carrier phase by raising QPSK to the fourth power and taking `angle/4` lands
  the constellation on 0/90/180/270°, but the reference lattice sits at 45°.
  The resulting EVM is about **76%**, which looks exactly like a broken radio.
- **Run the analysis against the clean transmit file first.** If the
  demodulator does not read ~0% on the waveform you generated, the bug is in
  the analysis.

## A WiFi hop in the path

A WiFi hop anywhere between host and board does not merely lower the rate; it
can collapse it. Conditions: a host with **no wired interface**, reaching the
board through WiFi and a router. The board's own Ethernet negotiated 1000 Mb/s
full duplex and the WiFi was strong (Wi-Fi 6, −47 dBm, 2 Gbit/s PHY rates).

| | |
|---|---|
| board against **itself** (loopback, no network) | **1.89 Gbit/s**, 0 retransmits |
| board at **1000 Mb/s**, through the WiFi hop | 679 Mbit/s burst, **807 retransmits**, then **7 Mbit/s for 24 s** |
| board at **100 Mb/s**, through the WiFi hop | no collapse; recovers to ~94 Mbit/s repeatedly, avg 48 |

The board is not the bottleneck: 1.89 Gbit/s over loopback with no loss shows
its network stack and its two Cortex-A9 cores are fine. A gigabit sender fills
buffers far faster than the WiFi hop drains them, and TCP does not recover
inside a thirty-second run. The congestion window stays frozen at 704 kB with
**zero** further retransmits: the sender is not even told to back off. The
collapse is not thermal (ten seconds at 252 Mbit/s moves the Zynq die by
**0.24 °C**, against an 85 °C limit), not the supply rails (all six pass), and
logs no kernel error.

**`iio_readdev` returns the byte count you asked for whether or not the DMA
overflowed.** A capture taken across one of those stalls looks perfect and is
not. If your path includes WiFi, use the USB gadget (a direct link at
`192.168.2.1`, no router) or a wired route, and do not expect any
sustained-rate figure on this page.

**There is no Ethernet flow control.** Every link-up logs
`macb ... Link is Up - 1Gbps/Full - flow control off`, and `ethtool -a eth0`
answers *"Operation not supported"*. The hardware is capable (the driver's
`macb_mac_link_up()` sets the GEM's `PAE`, Pause Enable, bit when `rx_pause` is
negotiated), but this `macb` driver implements no
`get_pauseparam`/`set_pauseparam`, so it cannot be configured from userspace,
and the board advertises `Transmit-only` against a switch offering
`Symmetric`. The board cannot be told to slow down: when it is overwhelmed,
frames are dropped and TCP has to infer congestion from loss. On a wired
gigabit path that does not matter, since the board's own stack does
1.89 Gbit/s. It does matter when something slower sits in between.

## What these numbers are not

- **Not a specification.** One board, one cable, one session.
- **The chirp flatness figure is a measurement artefact.** A chirp repeating
  every 8192 samples has a line spectrum, and the analysis window partly
  resolves those lines. The band-limited noise run, which has no line
  structure, gives the valid flatness figure: **0.81 dB**.
- **The sample-drop counts are not a rate.** Two to four events per two million
  samples is what these captures saw; it is occasional scheduling, and a busier
  host or network sees more.
- **Nothing here characterises `TX1A`/`RX1A`.** Only channel 1 was cabled.
- **The network figures include a WiFi hop** between host and router. A wired
  host should do at least as well; a different WiFi path can do much worse, see
  [above](#a-wifi-hop-in-the-path).

## Reproducing it

The board needs to be on Ethernet for anything above a few MSPS. Give it a
static address in the U-Boot environment and reboot:

```bash
# run on the BOARD
fw_setenv ipaddr_eth 192.168.129.200
fw_setenv netmask_eth 255.255.254.0
reboot
```

`S40network` reads those at boot and writes `/etc/network/interfaces`; leaving
`ipaddr_eth` empty falls back to DHCP. The USB gadget on `192.168.2.1` keeps
working either way, as a fallback route to the board.

From there the measurements are ordinary `libiio` calls. See
[Talking to the board](../.claude/skills/fishball7020-firmware/references/talking-to-the-board.md)
for the command forms. One rule applies to all of them:

> **Set transmit attenuation only after the DMA buffer is open, then read it
> back.** Writing it before a stream starts guarantees nothing. Every
> measurement on this page checked that both channels returned to the
> −89.75 dB floor afterwards.
