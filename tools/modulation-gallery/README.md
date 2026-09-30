# Modulation gallery — the measurement behind the pictures

Transmits ten modulations from the board, receives each one on a **HackRF One**,
measures it, and draws the figures in
[`docs/modulation-gallery.md`](../../docs/modulation-gallery.md). Everything is
seeded, so the transmitted reference regenerates exactly and a capture can be
re-analysed without going back on the air.

> **This tool radiates.** `campaign.py` and `spurs.py` transmit from the board
> through an **antenna on TX2A**, at 866.5 MHz by default; `hackrf_tx.py` and
> `decisive.py` make the HackRF transmit. The board reaches about +19 dBm.
> Pick a frequency you are licensed to use, and read
> [transmitter safety](../../docs/transmitter-safety.md) first.
>
> `campaign.py` mutes both chains and powers the TX local oscillator down in a
> `finally:` block, so an interrupted run does not leave the transmitter live.

## What you need

- the board reachable over libiio. It is found by name (`fishball.local`, then
  older names), then over USB at `192.168.2.1`; set `BOARD=<address>` to
  override. See [changing the board's IP address](../../docs/networking.md).
- a **HackRF One** with an antenna, and GNU Radio with the SoapySDR HackRF
  module (`gnuradio`, `soapysdr0.8-module-hackrf`)
- an antenna on **TX2A**, and a frequency you are allowed to transmit on
- numpy, scipy, matplotlib

## Run it

```bash
# run from: tools/modulation-gallery/
python3 dsp.py          # spectrum calibration, against analytic answers
python3 waveforms.py    # every waveform normalised and cyclic-seamless
python3 chain.py        # the anti-alias chain, and an interferer pushed through it
python3 rx.py           # the demodulator, against a synthetic channel of known SNR

python3 band.py         # what is actually on the air, and what only looks like it
python3 pickLO.py       # which receiver tuning leaves the analysis band cleanest

python3 campaign.py     # TRANSMITS: transmit, capture, measure  (~5 min)
python3 spurs.py        # TRANSMITS: attribute the spurs        (~2 min)

python3 fig1.py && python3 fig2.py && python3 fig3.py && python3 fig4.py && python3 fig5.py
```

Run the four self-tests first. Each has to pass before a real capture means
anything, and they take seconds. `band.py` and `pickLO.py` only receive.

`campaign.py` transmits on TX2A with the LO at 866.5 MHz, 4 MSPS, from a cyclic
DMA buffer, at −16 dB attenuation. The HackRF captures at 16 MSPS with a 12 MHz
analog filter, tuned 3.5 MHz *below* the board so its own DC spike lands in the
digital filter's stopband instead of on the signal. A muted reference is
captured first and every level is reported against it in absolute dBFS, because
a normalised spectrum makes silence look like structure.

## The files

| | |
|---|---|
| `waveforms.py` | the ten signals. All cyclic-seamless, because the board transmits from a repeating DMA buffer |
| `chain.py` | the receive chain: offset tuning, the anti-alias filter, decimation |
| `dsp.py` | spectra, PAPR, occupied bandwidth, each calibrated against a known answer |
| `rx.py` | carrier and timing recovery, EVM, the impairment budget, the chirp decoder |
| `board.py` | transmit from the Fishball7020 over libiio, safely |
| `hackrf_cap.py` | capture N samples from the HackRF, headless |
| `campaign.py` · `spurs.py` | the two measurement runs (both transmit) |
| `spurhunt.py` · `band.py` · `ip2.py` · `pickLO.py` | receiver-only diagnostics: is a peak a signal, a receiver spur, or a distortion product, and which tuning avoids it |
| `atlas2.py` · `twoears.py` | the same transmission heard by the board's own receiver and by the HackRF, which attributes a spur to one radio or the other |
| `whoselo.py` · `combclock.py` · `fs4.py` | does a spur follow either local oscillator, either sample rate, or neither |
| `hackrf_tx.py` · `decisive.py` | the HackRF transmits and the board receives: the one path with no shared reference. **Needs a receive antenna on the board** |
| `thirdparty.py` · `scaling.py` | two approaches to attributing the ±1 MHz pair that lack the sensitivity to succeed; kept so they are not repeated blind |
| `theme.py` · `palette.py` | the plot style, and the check that its colours are separable |
| `fig1.py` … `fig5.py` | the five figures |
| `atlas.json`, `spurs.json`, `summary.json` | results written by the measurement runs and read by the figures |

## Pitfalls

**Transmitting from a cyclic buffer needs a seamless waveform.** The board
repeats the buffer indefinitely; if the end does not join the beginning, the
seam sprays spurs across the span once per wrap and is measured as if it were
the modulation. Everything here is pulse-shaped by circular convolution and
checked by comparing one buffer's spectrum against four laid end to end.

**Set the transmit attenuation *after* the buffer starts, and read it back.**
Firmware patch 0005 restores a cached attenuation when a stream starts on a chip
that looks muted, so a value written before `OPEN` is not what goes on the air.
`board.py` writes it after and refuses to continue if the read-back disagrees.

**A peak in the spectrum is not necessarily a signal.** To tell:

- A real signal stays at the same absolute frequency when you retune the
  receiver. A receiver product moves or vanishes.
- If the peak is there with the transmitter muted, it is not the board's.
- A peak at exactly twice a strong carrier's baseband offset is the receiver's
  own second-order distortion of that carrier, landing at `2 × carrier − LO`.

Example: a strong carrier at 864.0 MHz produces a sharp peak 1.5 MHz below
centre. Tuning the receiver *above* the transmitter rather than below moves the
product 9.8 MHz away, where the digital filter removes it: 21.5 dB above the
noise floor becomes 3.8 dB. `spurhunt.py`, `band.py` and `ip2.py` reproduce the
diagnosis without transmitting.

**"It tracks the carrier" does not say whose spur it is.** A spur that a
*receiver's* local oscillator stamps onto a carrier scales with that carrier
exactly as a transmitter's own sideband does, so a constant ratio in dBc over a
power sweep proves only that the mechanism is multiplicative. Attributing a
multiplicative spur needs a second receiver, not a power sweep. The ±1 MHz pair
around the carrier is an example: it sits at a fixed 1.000 MHz regardless of
transmit rate, and a second receiver puts it 26 dB weaker through the board than
through the HackRF, so it is not in what the board transmits.

**The board's own receiver is not fully independent of its transmitter.** Its
transmit and receive synthesisers come from a single 40 MHz reference, so a
perturbation of that reference lands on both and cancels in the loopback, by
20·log10(f/Δf), about 53 dB at a 2 MHz separation. "Absent from the board's
receiver" therefore means *either* absent from the transmitter *or*
reference-borne, and the two cannot be told apart that way. Breaking the tie
needs a receive antenna on the board so the HackRF can transmit to it, which is
what `decisive.py` does.

**Check the analysis before trusting it.** `rx.py`'s self-test runs the whole
demodulator on a synthetic channel at a known signal-to-noise ratio and requires
the EVM that comes out to match the EVM that must come out. The synthetic
channel must apply the frequency offset *after* any rotation of the sample
buffer: rolling the signal after the offset creates a phase discontinuity no
real transmission has, and the EVM reads the same wrong value at every SNR.
