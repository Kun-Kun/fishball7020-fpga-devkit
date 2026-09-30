# Ten modulations, received on a HackRF One

What one Fishball7020 puts on the air for ten modulations, from a CW tone to
64-QAM, OFDM and a LoRa-style chirp, received over the air on a separate radio:
spectra, constellations, EVM, PAPR, and which spurs belong to the board. Use it
to see what the transmitter can do, and as a worked method for attributing
spurs between two radios. All the code is in
[`tools/modulation-gallery/`](../tools/modulation-gallery/).

To repeat it (this transmits; see [Repeating it](#repeating-it) first):

```bash
# run from: tools/modulation-gallery/
python3 campaign.py            # transmit each signal, capture it, measure it
python3 fig1.py                # ... through fig5.py, redraw the figures
```

The receiver is a **HackRF One**, an independent instrument. A board receiving
its own transmission shares one clock with itself, which hides every oscillator
problem; two radios with separate clocks hide none.

![Ten modulations transmitted by a Fishball7020 and received on a HackRF One. Ten spectrum panels in a grid: CW tone, OOK, 2-FSK, BPSK, QPSK, GMSK, 16-QAM, 64-QAM, OFDM and a LoRa-style chirp, each showing about 85 dB of dynamic range above the muted noise floor.](img/modulation/01-signal-set.png)

## The setup

| | |
|---|---|
| Transmitter | Fishball7020, Zynq XC7Z020 + AD9361, **TX2A**, 866.5 MHz, 4 MSPS, −16 dB attenuation |
| Receiver | **HackRF One**, 16 MSPS, 12 MHz analog filter, LNA 24 dB / VGA 24 dB, tuned **4.8 MHz above** the transmitter |
| Band | 866.5 MHz, inside the European 863–870 MHz ISM band |
| Link | over the air, a short hop across a desk |

**Terms.** *EVM* (error vector magnitude) is how far each received symbol
lands from where it should, as a percentage of the signal's own size; smaller
is better. *PAPR* (peak-to-average power ratio) is how much louder the loudest
moment is than the average; it decides how much headroom an amplifier must
keep in reserve. A *constellation* is a plot of every received symbol as a
dot, so the pattern shows the modulation and the blur shows the damage.
*Equalised* EVM is after a filter that removes the link's linear distortion.

## Results

| Signal | Tier | Occupied BW | PAPR | EVM | |
|---|---|---|---|---|---|
| CW tone | simple | 0.003 MHz | 0.22 dB | — | the reference |
| OOK | simple | 0.304 MHz | 4.95 dB | — | 250 kbaud |
| 2-FSK | simple | 0.854 MHz | 0.32 dB | — | 250 kbaud, ±250 kHz |
| BPSK | moderate | 1.164 MHz | 4.02 dB | 6.45 % | 5.90 % equalised |
| QPSK | moderate | 1.163 MHz | 3.69 dB | 6.34 % | 5.91 % equalised |
| GMSK | moderate | 0.994 MHz | 0.30 dB | — | BT = 0.3 |
| 16-QAM | complex | 1.165 MHz | 5.58 dB | 6.10 % | 5.98 % equalised |
| 64-QAM | complex | 1.164 MHz | 6.06 dB | 9.35 % | 6.05 % equalised |
| OFDM, 52 × QPSK | complex | 1.648 MHz | 9.47 dB | 10.61 % | 128-point FFT, ¼ cyclic prefix |
| LoRa-style CSS | complex | 0.990 MHz | 4.84 dB | — | **128 of 128 symbols decoded** |

All the linear modulations run at 1 Msym/s with root-raised-cosine shaping,
α = 0.35.

## Constellations

![Constellations measured over the air: BPSK, QPSK, 16-QAM, 64-QAM and OFDM, each a density-shaded cloud of received symbols with amber rings marking the transmitted positions.](img/modulation/02-constellations.png)

The 64-QAM grid is fully resolved: all 64 points separate cleanly. That says
more about the transmitter than the EVM number beside it.

## The EVM floor belongs to the link

Every linear modulation lands at **5.9–6.1 % EVM after equalisation**, the same
for BPSK as for 64-QAM. A transmitter running out of linearity punishes dense
constellations far harder than sparse ones; an impairment that is identical
across four modulation orders is additive, and comes from the link rather than
from the board.

Three measurements, all in the figure below, place it:

- **An unmodulated carrier through the same path already shows 8.7 %
  equivalent EVM** (7.4 % on another run), of which 4.97° is RMS phase error
  (4.22° on the other run) and only 0.78 % is amplitude. A CW tone has no
  modulation to get wrong, so the transmitter's modulator does not cause it.
  That it wanders between runs also argues against a fixed impairment.
- **In-band signal-to-noise is 42–45 dB**, which on its own would allow
  0.6–0.8 % EVM. Noise is not the limit.
- **Image rejection is 55.0–64.9 dB**, from fitting the received symbols to
  `a·s + b·conj(s)`. That is a widely linear fit, which catches I/Q imbalance
  because no ordinary equaliser can. The board's I/Q balance is fine.

What remains is phase noise between two independent oscillators, a property of
the measurement setup rather than of the radio. On the OFDM constellation it is
visible directly: the clouds are stretched tangentially, around the origin,
which is what a phase error does and an amplitude error does not.

![Four summary panels: PAPR as a complementary cumulative distribution for six signals; EVM per modulation before and after equalisation against the link's own 8.7 percent floor; the link's phase noise in dBc per hertz; and each CW spur heard by two receivers, where four features agree and the two at one megahertz are absent from the board's own receiver.](img/modulation/05-summary.png)

## Whose spur is it?

The CW spectrum has companions around the carrier, and a plot on its own
cannot say which radio made them.

**Turning the transmitter down is not a sufficient test.** A constant dBc ratio
separates an *additive* receiver artefact (which grows faster than the signal)
from anything multiplicative. But a spur that a **receiver's** local oscillator
stamps onto a carrier scales with that carrier exactly as a transmitter's own
sideband does, so a constant dBc ratio fits either radio.

**A second receiver does separate them.** The board has its own, and internal
TX→RX leakage is strong enough to use it without any antenna. A feature present
in the transmitted signal appears on both receivers at the same level relative
to the carrier; one made inside a receiver appears on that one alone.

Conditions: the gallery's operating point, both receivers set for the same
70 dB of dynamic range, neither clipping.

| Feature, relative to the transmit LO | Board's own receiver | Through the HackRF | |
|---|---|---|---|
| carrier feedthrough (on the LO) | −46.9 dBc | −47.3 dBc | **the board's** |
| I/Q image of the tone (−600 kHz) | −57.9 dBc | −57.6 dBc | **the board's** |
| 2nd harmonic of the tone (−1200 kHz) | −64.5 dBc | −65.7 dBc | the board's, near the floor |
| 3rd harmonic of the tone (−1800 kHz) | −40.8 dBc | −43.5 dBc | **the board's** |
| tone − 1.000 MHz | −68.5 dBc | −42.0 dBc | **not the board's** |
| tone + 1.000 MHz | −66.5 dBc | −42.0 dBc | **not the board's** |

The board's own noise floor in that measurement is −68.6 dBc, so the last two
rows are *at* its floor: absent. The first four agree between two independent
receivers to within 3 dB, which also validates the method.

**The board's own contributions to a CW spectrum** are carrier feedthrough at
about −47 dBc, an I/Q image at −58 dBc, and a third-order product at −41 dBc.
The ±1 MHz pair is not among them.

## The 8 kHz comb and the ±1 MHz pair

Around the carrier sits a comb of lines spaced **exactly 8.000 kHz**, each
flanked by satellites ±1.95 kHz away, plus a pair at exactly ±1.000 MHz.

What the measurements establish about them:

- **They are pure phase modulation.** Decomposing the sidebands into amplitude
  and phase puts every one 40–50 dB further down in AM than in PM (at 40 kHz,
  −91 dBc of AM against −48 dBc of PM). Something modulates an oscillator's
  phase, not the amplitude of anything.
- **Not a sampling artefact.** The comb stays at 8.000 kHz with the transmit
  rate at 4, 5 or 8 MSPS and the receive rate at 12, 16 or 20 MSPS.
- **Not a fractional-N synthesiser spur.** Those move when the synthesiser is
  retuned; these do not, for either radio, at any tuning tried.
- **The ±1 MHz pair is not at a quarter of the transmit rate.** At 4 MSPS,
  fs/4 is 1 MHz by coincidence. Changing the transmit rate leaves the pair at
  exactly 1.000 MHz (−43.2 dBc at 4, 5 and 8 MSPS) while fs/4 of the new rates
  holds nothing (−72 to −75 dBc).
- **Neither is in what the board transmits**, by the two-receiver table above:
  26 dB weaker through the board's own receiver, which is its noise floor.

**The comb is the HackRF's.** The board's own loopback cannot attribute it,
because the board's transmit and receive synthesisers come from one 40 MHz
reference, and a perturbation *of that reference* cancels there by about
53 dB. With an antenna on the board's RX1, the reverse path (**HackRF
transmits, board receives**) shares nothing with the board's transmitter:

| | 8 kHz comb | ±1.000 MHz pair |
|---|---|---|
| board transmits → HackRF receives | −48 dBc | −42 dBc |
| HackRF transmits → board receives | **−66 dBc** | −43 to −51 dBc |
| board transmits → board receives | at its floor, −68.6 dBc | at its floor |

The comb comes back **18 dB weaker** when the board is the receiver. On the
board's 40 MHz reference it would appear at full strength through the board's
receive oscillator, whose multiplier is within 0.2 % of the transmit one. A
spur on the board's transmit PLL specifically, rather than the reference, would
not cancel in the loopback, where there is nothing.

**The ±1 MHz pair's origin is unresolved.** It is certainly not in what the
board transmits, and probably the HackRF's too. It comes back at a similar
level in both directions, which fits the HackRF's synthesiser (shared between
its transmit and receive) and fits the board's reference equally well. Two
tests do not settle it:

- Receiving a third-party carrier on the board would show whether its receive
  oscillator stamps the pair onto a signal neither radio made. The only strong
  carrier nearby is too weak at the board: the phase-noise floor comes out
  −50 dBc, the 1 MHz line within 4 dB of a control bin, and the carrier's
  frequency drifts between runs.
- Repeating at 2.45 GHz tests whether the pair scales with the board's
  multiplier (+9.0 dB from 865 MHz). The result is +4.9 dB, but **both**
  hypotheses predict +9 dB, because the HackRF's multiplier scales with
  frequency the same way. The test cannot discriminate.

`whoselo.py`, `combclock.py`, `fs4.py`, `twoears.py`, `atlas2.py` and
`decisive.py` in
[`tools/modulation-gallery/`](../tools/modulation-gallery/) reproduce each step.

## The peak that was not a signal

**Symptom.** With the receiver tuned below the transmitter, every spectrum
shows a sharp peak **1.5 MHz below centre**, modulated or not. It is there with
the transmitter muted and does not move with 20 dB of transmit power, so it is
not the board. It sits at 865.0 MHz, inside the European UHF RFID band, which
suggests an external transmitter.

**It is not a real signal.** A real signal stays at the same absolute frequency
when the receiver is retuned. This one does not:

| Receiver tuned to | 865.0 MHz would appear at | level above the noise floor |
|---|---|---|
| 858.0 MHz | +7.000 MHz | 1.3 dB |
| 861.0 MHz | +4.000 MHz | 4.9 dB |
| **863.0 MHz** | **+2.000 MHz** | **26.7 dB** |
| 867.0 MHz | −2.000 MHz | 3.2 dB |
| 870.0 MHz | −5.000 MHz | 2.5 dB |

Present at one tuning and absent at the other four. Nothing is at 865.0 MHz.

**Cause: second-order distortion in the HackRF's mixer.** A strong carrier at
**864.0 MHz** shows up at every tuning, at exactly 864.0 MHz each time
(+7.000 from an 857 MHz tuning, +4.000 from 860, +1.000 from 863, −2.000 from
866, −5.000 from 869). 865.0 MHz is precisely twice its offset from a receiver
tuned to 863.0. Second-order distortion turns a strong input at baseband offset
*d* into a product at *2d*, so the product moves at twice the rate the carrier
does, in the same direction. It does, at every tuning tried:

| Receiver tuned to | 864.0 MHz sits at | product predicted at | level there | a control bin 400 kHz away |
|---|---|---|---|---|
| 862.5 MHz | +1.500 MHz | +3.000 MHz | 18.1 dB | 11.3 dB |
| 863.0 MHz | +1.000 MHz | +2.000 MHz | 29.0 dB | 2.2 dB |
| 863.5 MHz | +0.500 MHz | +1.000 MHz | 15.1 dB | 3.1 dB |
| 864.5 MHz | −0.500 MHz | −1.000 MHz | 15.3 dB | 2.2 dB |
| 865.0 MHz | −1.000 MHz | −2.000 MHz | 14.6 dB | 2.5 dB |

**Fix: tune the receiver above the transmitter.** The product lands at
`2 × carrier − LO`, so the *receiver's* tuning decides where it falls. Tuning
**4.8 MHz above** the transmitter instead of 3.5 MHz below moves the product
from 865.0 MHz to 856.7 MHz, 9.8 MHz from the signal and deep in the digital
filter's stopband. At −1.5 MHz the peak drops from **21.5 dB above the noise
floor to 3.8 dB**. Every spectrum on this page uses the 4.8 MHz-above tuning.

With the interferer out of the measurement, two other figures also tighten: the
board's ±1 MHz spur reads −41.8 to −42.0 dBc across the whole 20 dB sweep
(below tuning, it drifts to −30.5 dBc at the lowest power, where the interferer
dominates), and the equalised EVM range narrows from 6.01–6.17 % to
5.90–6.05 %.

`spurhunt.py`, `band.py`, `ip2.py` and `pickLO.py` in
[`tools/modulation-gallery/`](../tools/modulation-gallery/) reproduce this.
None of them transmits; it is entirely a receiver question.

## The chirp

![A LoRa-style chirp spread spectrum signal: a wide spectrogram showing a staircase of diagonal chirps, a dechirped FFT with a single sharp peak 55.6 dB above the median bin, a scatter of decoded against transmitted symbols lying exactly on the diagonal, and the signal envelope.](img/modulation/03-chirp.png)

Spreading factor 9 over 1 MHz: 512 possible symbols, each the same up-chirp
cyclically shifted. Dechirping collapses each one to a single tone whose FFT
bin *is* the symbol; here that peak stands **55.6 dB above the median bin**.
All 128 symbols in the buffer come back correct.

A chirp is nominally constant-envelope, and this one shows 4.84 dB of PAPR.
That is expected: band-limiting it to its own 1 MHz channel turns the frequency
wrap at each symbol boundary, a genuine discontinuity, into envelope ripple.

## Time domain

![Eight panels: the CW tone as two sinusoids ninety degrees apart, OOK as a switching envelope, 2-FSK and GMSK as instantaneous frequency traces, and eye diagrams for BPSK, QPSK, 16-QAM and 64-QAM showing two, two, four and eight distinct levels.](img/modulation/04-time-domain.png)

The eye diagrams are drawn from the same matched-filter output the EVM is
computed on, so they show the same signal, not an illustration of it. The
number of distinct levels at the sampling instant (two, two, four, eight) is
the modulation order.

## How the plots are kept accurate

**No DC spike, and no distortion products.** A direct-conversion receiver puts
a large artefact at its own local-oscillator frequency, and on most SDR
screenshots it sits in the middle of the signal. Here the HackRF is tuned
**4.8 MHz above** the transmitter, so that artefact lands in the stopband of the
digital filter that follows and is rejected by 144 dB rather than blanked. The
same tuning also moves the mixer's second-order products clear of the band
(see [the section above](#the-peak-that-was-not-a-signal)).

**No aliasing.** 16 MSPS with a 12 MHz analog filter puts the fold point 2 MHz
inside the analog stopband. The digital filter that follows passes 2 MHz, stops
at 2.6 MHz and reaches 120 dB, and decimation to 8 MSPS then has 2 MHz of
margin. Through this chain, a DC artefact twelve times the wanted signal and an
interferer six times it come out 113 dB down. The plots are reduced for display
by per-pixel min and max rather than by dropping points, because drawing
32 768 spectrum bins into 1 100 pixels aliases the *picture* too.

**The measurement chain is checked against known answers.** The spectrum
estimator must read a full-scale tone as 0 dBFS and unit-variance noise as
−10·log₁₀(fs) dBFS/Hz. The demodulator must return, on a synthetic channel at a
known signal-to-noise ratio, the EVM that the noise implies (including the
matched filter's processing gain). A synthetic channel must not roll the signal
after applying the frequency offset: that creates a phase discontinuity no real
transmission has, and the demodulator then reads 17.5 % EVM at every SNR. The
checks:

```bash
# run from: tools/modulation-gallery/
python3 dsp.py          # spectrum calibration against known answers
python3 waveforms.py    # every waveform normalised and cyclic-seamless
python3 rx.py           # the demodulator, against a known synthetic channel
python3 chain.py        # anti-alias filter, and what it does to an interferer
```

## Repeating it

Everything the board transmits is generated from a fixed seed, so the
reference regenerates exactly and the captures can be re-analysed without
transmitting again. `campaign.py` transmits, captures and measures each signal;
`fig1.py` through `fig5.py` redraw the figures (commands at the
[top of this page](#ten-modulations-received-on-a-hackrf-one)).

You need a HackRF (or any SoapySDR receiver, by editing `hackrf_cap.py`), GNU
Radio for the capture, and the board reachable over libiio. `board.py` takes
the board's address as its argument; see [changing the board's IP
address](networking.md) if it is not on the default.

> **Transmitting.** These runs put a real signal on a real antenna. 866.5 MHz
> is inside the European ISM band, and the levels here are low, but the band
> has duty-cycle and power limits and the rules differ by country. What leaves
> the antenna port is the operator's responsibility; see [transmitter
> safety](transmitter-safety.md).

## What this page does not establish

- **Absolute transmit power.** Nothing here is in dBm; every level is relative
  to the receiver's full scale. The board's output power is estimated
  elsewhere, never read on a power meter; see
  [board performance](measured-performance.md).
- **The board's true EVM.** The link's own floor (7.4–8.7 % across runs) sits
  above whatever the transmitter contributes, so these figures are an upper
  bound on the board's modulation error, not a measurement of it. Separating
  the two needs either a shared reference clock between the two radios or a
  better receiver.
- **Behaviour at full power.** Everything here is at −16 dB attenuation, inside
  the amplifier's linear region. Compression is a different experiment.
