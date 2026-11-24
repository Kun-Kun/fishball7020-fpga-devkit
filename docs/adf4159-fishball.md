# ADF4159 evaluation board with Fishball 7020

This is a wiring and feasibility reference for programming an ADF4159 from
Fishball and using its VCO's chirp as the AD9361 transmit and receive LO. The
exact evaluation board suffix and fitted VCO must be checked before the RF
connection is made.

## Digital voltage and available pins

The local [ADF4159 data sheet](vendor/ADF4159.PDF), Rev. B, Tables 1, 2 and 4,
specifies DVDD/SDVDD = 1.62–1.98 V, digital input high ≥1.4 V and low ≤0.4 V,
and an absolute digital-pin limit of DVDD + 0.3 V. CLK, DATA, LE, TXDATA and CE
are digital inputs; MUXOUT is a digital output. **Do not wire a Fishball 3.3 V
or 2.5 V output directly to any of those inputs.** A 2.5 V signal also exceeds
the ADF4159's absolute limit at nominal DVDD = 1.8 V.

The [Fishball schematic](vendor/7020_936x_SDR-schematic.pdf), sheet 1, ties
FPGA bank 13 to 3.3 V and banks 34/35 to **1.8 V**. There is no 2.5 V FPGA
bank or 2.5 V header supply on this board. Patch
[`0037`](../firmware/patches/0037-adf4159-jp5-1v8-spi.patch) corrects the
bank-35 single-ended settings in
[`system_constr.xdc`](../firmware/src/hdl/projects/pluto/system_constr.xdc)
to `LVCMOS18`; the inherited bank-34 constraints remain as they were.

The patched source routes the existing PL AXI SPI controller and one EMIO
GPIO to JP5's bank-35 pins. The block design names the ADF SPI signals,
keeps the AD9361 on its separate PS SPI0 bus, and ties the PL controller's
unused slave inputs to constants. The Linux device tree declares FCLK0 as
the PL SPI clock and exposes chip select 0 as a raw SPI device. Vivado
confirms every listed FPGA ball is in
bank 35; Fishball schematic sheets 5 and 13 identify the header nets and pins:

| ADF4159 signal | Fishball port | JP5 pin | FPGA ball | Header net |
|---|---|---:|---|---|
| CLK | `pl_spi_clk_o` | 16 | L14 | `1V8_IO7_P` |
| DATA | `pl_spi_mosi` | 18 | L15 | `1V8_IO7_N` |
| LE | `pl_spi_le` | 12 | H16 | `1V8_IO5_P` |
| MUXOUT, optional readback | `pl_spi_miso` | 14 | H17 | `1V8_IO5_N` |
| TXDATA, optional ramp trigger | `adf_txdata` (EMIO GPIO 17, Linux line 71) | 4 | G19 | `1V8_IO1_P` |

Use JP5 pin 2 or 20 for common ground. The AXI SPI chip select is high at
idle, low while a word shifts, then rises to latch the ADF4159 word on LE.
Write **one 32-bit word per SPI transaction**, most-significant byte and bit
first, with mode 0. Sending several words in one transaction would give only
one LE rising edge. The PL SPI clock is fixed at 12.5 MHz by the current IP
configuration, below the data sheet's 20 MHz limit from its 25 ns minimum
high/low periods. DATA setup/hold minima are 10 ns and LE pulse width is
20 ns. The final three bits select R0–R7. The ADF4159 generates FMCW ramps
internally after programming; SPI only writes the configuration. MUXOUT is
not an ordinary always-on SPI MISO data stream: its readback function must be
selected and clocked per the ADF4159 readback procedure.

The device-tree patch exposes this bus as `/dev/spidev*.0` after building and
deploying the new firmware; find its actual bus number on the board. TXDATA
is named `adf_txdata` on Linux GPIO line 71, but is left as an input and held
low by the FPGA pull-down until software drives it. The same source retains
the four 3.3 V `sample_gpio` pins on JP5 pins 7/9/11/13 as a separate option
through a 3.3 V-to-1.8 V translator. Those are not needed for the direct
1.8 V SPI path.

### The evaluation board control lines

The [EV-ADF4159EB1Z/EB3Z user guide](https://www.analog.com/media/en/technical-documentation/user-guides/UG-383.pdf),
Figure 10 and Figure 12, shows an onboard USB controller wired to CLK, DATA,
LE, CE and TXDATA. CLK/DATA/LE have 330 Ω series resistors from that controller
and 390 Ω pull-downs at the ADF4159 side. Its USB controller is a 3.3 V
device; the resistor network is part of *that board's* interface. It is not
permission to put 3.3 V directly on the ADF4159 pin. Verify the exact board
revision and isolate the onboard controller before another driver is attached,
then connect the Fishball 1.8 V signals on the ADF4159 side of the series
resistors. The guide shows CE pulled to 1.8 V through 10 kΩ. If the actual
board lacks these parts or has different routing, follow its own schematic.

## Live 4.5 GHz test with the HMC586

On 2026-11-02, an HMC586 4–8 GHz VCO was connected to the ADF4159 loop.
Its RF output fed Fishball RX1 through a 20 dB attenuator and a 30 cm coax.
The ADF4159 evaluation board's onboard 100 MHz reference was used with
R = 1, giving a nominal 100 MHz PFD frequency. Each register below was
written as a separate, four-byte, MSB-first SPI transaction to
`/dev/spidev1.0`:

| Register | Word / SPI bytes | Relevant settings |
|---|---|---|
| R3 | `0x00000003` / `00 00 00 03` | Negative phase detector polarity; charge pump tri-state off |
| R2 | `0x0000800A` / `00 00 80 0A` | Charge pump code 0, nominal 0.31 mA with 5.1 kΩ RSET; R = 1 |
| R0 | `0x30168000` / `30 16 80 00` | Integer N = 45; 4.5 GHz target; digital lock detect selected on MUXOUT |

The R2 charge pump setting is double buffered; write R0 after R2. The
[ADF4159 data sheet](https://www.analog.com/media/en/technical-documentation/data-sheets/adf4159.pdf)
defines the current codes, phase detector polarity and tri-state bit. The
[evaluation-board guide](https://www.analog.com/media/en/technical-documentation/user-guides/UG-383.pdf)
specifies negative polarity for its inverting active loop filter.

With RX1 tuned to 4.499 GHz, the 30.72 MSPS capture showed a narrow tone
near +1.01 MHz. The pump/polarity/tri-state sweep gave:

| Phase detector | Pump codes | Tri-state | RX1 spectrum |
|---|---|---|---|
| Negative | **0** | Off | Narrow tone about 54 dB above the spectral median |
| Negative | 1–15 | Off | Broad signal without a comparable narrow tone |
| Positive | 0–15 | Off | Noise floor |
| Either | 0, 7, 15 | On | Noise floor after settling |

At 0 dB manual RX gain, repeated 65,536-sample captures with code 0 gave
about **−27.5 dBFS complex RMS** (relative to 2048 ADC counts) through the
20 dB attenuator. Changing N from 45 to 46 moved the narrow signal with an
RX LO shift from 4.499 to 4.599 GHz; returning to N = 45 restored the original
tone. This shows that the RF output follows the programmed divider. MUXOUT
readback through the current SPI MISO connection did not give a reliable
digital lock indication, so lock status and phase noise remain unverified.
After the test, N = 45, pump code 0, negative polarity and tri-state off were
left programmed; RX1 was restored to its original 2.4 GHz LO and slow-attack
AGC.

### Measured low-frequency edge

A follow-up sweep used the same 20 dB attenuator, 0 dB RX1 gain and 30.72 MSPS
capture. Integer-N steps gave a narrow, divider-following tone down to 4.0 GHz.
The ADF4159's 25-bit fractional divider was then used to test below 4.0 GHz:
write R1's fractional LSBs first, then R0 with the integer and fractional
MSBs. R2 and R3 remained as listed above.

The **lowest repeatably controlled setting in this session was 3.905 GHz**.
Its register words were R1 `0x0CCD0001` and R0 `0x30138660`. With RX1 at
3.904 GHz, two captures several seconds apart showed a tone near +1 MHz,
about 49–50 dB above the spectral median, and −34.8 dBFS complex RMS.
Holding the RX LO at 3.904 GHz while changing only the ADF4159 from
3.905 to 3.910 GHz moved the tone from +0.997 to +6.024 MHz. The 3.910 and
3.920 GHz settings also produced repeatable narrow tones.

Settings at 3.902–3.904 GHz sometimes produced a tone on a single pass but
did **not** reproduce after retuning from 4.1 GHz and waiting. A 3.900 GHz
command did not produce a tone at its target frequency. With the PLL
commanded to 3.88, 3.85 and 3.80 GHz, the RF instead stayed around
**3.89277 GHz**, measured with the RX LO fixed at 3.892 GHz. Moving only
the RX LO by 9 MHz moved this tone by 9 MHz, confirming that it was RF from
the VCO path. This is the lowest **observable oscillation** in the test, not
a controlled 3.80–3.88 GHz output or evidence of PLL lock. The apparent
3.905 GHz control edge can change with tuning history, temperature and loop
conditions; it is below the HMC586's specified 4–8 GHz range. The ADF4159
was returned to the 4.5 GHz target after the sweep, and RX1 to its original
2.4 GHz LO and slow-attack AGC.

**RF power at the VCO connector has not been measured.** The −27.5 dBFS
capture and AD9361 RSSI readback cannot be converted to dBm without a
calibrated RX path: [UG-570](https://www.analog.com/media/en/technical-documentation/user-guides/ad9361.pdf)
explicitly requires system calibration for absolute RSSI. The
[HMC586 data sheet](https://www.analog.com/media/en/technical-documentation/data-sheets/hmc586.pdf)
lists **+5 dBm typical** VCO output. If this particular output meets that
typical value, the 20 dB pad would put roughly −15 dBm at RX1 before coax
and connector loss. That is an estimate, not a power measurement.

## Driving the AD9361 external LO

The ADF4159 is a **PLL controller**, not an RF oscillator. It needs a VCO,
appropriate loop filter, power, and reference. The
[evaluation-board guide](https://www.analog.com/media/en/technical-documentation/user-guides/UG-383.pdf)
says the EB1Z version has an 11.5–12.5 GHz HMC515 VCO; the EB3Z has **no VCO**
and needs an external one. EB1Z's fitted VCO cannot provide the 2–4 GHz LO
needed to sweep Fishball's AD9361 RF tuning from 1–2 GHz.

The [AD9361 reference manual, UG-570](https://www.analog.com/media/en/technical-documentation/user-guides/ad9361.pdf),
External LO section, requires an external LO at **twice the desired RF LO**:
2–4 GHz for a 1–2 GHz RF sweep. Both TX and RX must receive that same
frequency. Fishball's [schematic](vendor/7020_936x_SDR-schematic.pdf), RF sheet,
routes U.FL `RF2` to `TX_EXT_LO_IN` (AD9361 ball A12) and `RF3` to
`RX_EXT_LO_IN` (ball G1); check that both U.FL connectors are fitted on the
particular board. Split a suitable VCO output into two paths and
measure power at each AD9361 pin. UG-570 recommends −3 to +3 dBm there and
sets +6 dBm as the maximum. The RF2/RF3 schematic paths show no series DC
blocking capacitor or 50 Ω termination; [ADI's external-LO guidance](https://ez.analog.com/rf/wide-band-rf-transceivers/design-support/f/q-a/80585/ad9361-external-lo-inputs/87711)
calls for AC coupling and, at high frequency, termination near the input.
Plan those parts in the RF feed and verify the resulting level at the chip.

Finally, the AD9361 must be configured for external TX and RX LO in its driver;
wiring RF2/RF3 alone does not switch off the internal synthesizers. A shared
reference between the ADF/VCO and the AD9361 is needed if their chirp timing
must remain coherent. The two boards' default references are separate (the
ADF evaluation board uses 100 MHz; Fishball uses 40 MHz).

### Applying this HMC586 output

The tested **4.5 GHz** VCO output is within the AD9361's 140 MHz–8 GHz
external-LO input range. Its internal divide-by-two makes a **2.25 GHz TX/RX
RF LO**. The HMC586's specified 4–8 GHz tuning range therefore corresponds
to 2–4 GHz RF LO operation with external LO. This board briefly controlled
the VCO down to 3.905 GHz, or 1.9525 GHz RF LO, but that is below the VCO's
specified range and marginal in the repeat tests. It cannot support a full
1–2 GHz RF chirp. Use the connector that actually carries the full VCO
frequency, and verify its frequency if the evaluation board has a separate
`VCO/2` output.

For simultaneous TX and RX external LO, split the 4.5 GHz output into two
matched RF paths feeding Fishball `RF2` (TX LO) and `RF3` (RX LO). **Remove
the 20 dB RX1 test attenuator from these LO paths.** A nominal +5 dBm source
followed by an ideal two-way splitter offers about +2 dBm of available power
per matched 50 Ω branch, before splitter insertion loss, cables and other
losses. That is a plausible starting point for the AD9361's recommended
−3 to +3 dBm **at each chip pin**, not a measurement of the pin level.
Measure the level at the board input and account for the board path. Do not
connect the unmeasured source directly to a single LO input:
the nominal +5 dBm is above the +3 dBm recommendation and leaves only 1 dB
below the +6 dBm maximum. Add AC coupling; ADI recommends resistive
termination near the pin at high frequency because the AD9361 has no
internal termination. The Fishball schematic does not show either component
on RF2/RF3. Check the fitted paths before connection. The board currently
reports
`out_altvoltage0_RX_LO_external=0` and
`out_altvoltage1_TX_LO_external=0`; both must be enabled for external LO use.

## External-LO FMCW loopback measurement

On 2026-11-03 the HMC586 output was connected to both AD9361 external LO
inputs, and TX2A was connected through a coax and 20 dB pad to RX2A. Both
external LO switches read `1` and the AD9361 was in `fdd`. The ADF4159 used
the same 100 MHz reference, R = 1, negative phase detector polarity and
charge-pump code 0 as the CW test above. Its continuous sawtooth used 200
steps at 5 µs per step (1 ms period). The ADF4159 [ramp equations and register
order](https://www.analog.com/media/en/technical-documentation/data-sheets/adf4159.pdf)
give `CLK1 = 500`, `CLK2 = 1`, and a 250.006 kHz VCO step with
`DEV = 10486`, `DEV_OFFSET = 3`. The AD9361 divides the shared external LO
by two, so the RF LO swept from 2.250 to about 2.275 GHz. A second run
halved `DEV` to 5243.

The TX2 FPGA path sent a repeating ±15 MHz baseband chirp at 61.44 MSPS.
TX2 attenuation was −35 dB, RX2 manual gain was 55 dB, and the RX2 FPGA
dechirp output was captured at 7.68 MSPS. Each CW and ramp capture contained
262,144 complex samples, about 34 chirps. The ramp starts at an arbitrary
phase relative to the TX waveform because the ADF and Fishball have separate
reference clocks. The measurement folds each capture at the TX period,
aligns the TX reset notch, and takes the dominant local phase slope of the
ramp/CW ratio away from the reset and baseband DC crossing. That gives the
**ramp-added beat**; adding it to the CW beat gives an estimated total beat
in the steady part of the ramp.

| Programmed VCO ramp / 1 ms | RF LO span | CW beat | Ramp-added beat | Estimated steady ramp beat | Effective delay |
|---|---:|---:|---:|---:|---:|
| 4.500–4.550 GHz | 25.001 MHz | −799.1 Hz | **−74.12 Hz** | −873.21 Hz | 2.96 ns |
| 4.500–4.525 GHz | 12.500 MHz | −798.5 Hz | **−35.48 Hz** | −834.00 Hz | 2.84 ns |

The roughly halved added beat when the slope was halved supports the FMCW
interpretation. The effective delay includes the coax, TX/RX analog paths and
their LO distribution; it is not a standalone coax-length measurement. The
earlier calibrated 30 cm path was about 4 ns total near 1–2 GHz, and this
2.25 GHz experiment uses a different frequency and waveform. An independent
RF probe did not measure the VCO ramp or PLL lock directly. The beat is a
periodic signal with a reset transient, so a whole-record FFT does not have
one exact beat line.

Reproduce with both external LO switches already set to `1`, `ensm_mode=fdd`,
the TX2/RX2 20 dB pad connected, and the TX2 guard affirmed:

```sh
./devkit tx-guard affirm 1
.venv/bin/python tools/adf4159_ramp_beat.py \
  --output artifacts/adf4159-ramp-beat-full
.venv/bin/python tools/adf4159_ramp_beat.py --deviation-word 5243 \
  --output artifacts/adf4159-ramp-beat-half
```

Each run saves `report.json` and `rx2_beat_iq.npz`, mutes both transmitters,
restores the AD9361 tuning/gain settings, and returns the ADF4159 to 4.5 GHz
CW. On this board, changing an external LO switch back to `0` once left the
AD9361 in `alert` with a calibration timeout; a reboot restored `fdd`.
The measurement tool therefore requires the external LO switches to be
enabled before it starts and does not change them.

## Web API and test page

Run [`tools/adf4159_web.py`](../tools/adf4159_web.py) on the development PC.
It connects to Pluto as `root` over SSH for ADF register writes and RX1 tests.
Beat capture also needs the native CGI service installed on the board (below).
The board must have the JP5 SPI firmware, `/dev/spidev1.0` and `xxd`. Install
[`tools/adf4159-web-requirements.txt`](../tools/adf4159-web-requirements.txt)
into the project Python environment for the RX spectrum test, then start:

```sh
.venv/bin/python -m pip install -r tools/adf4159-web-requirements.txt
.venv/bin/python tools/adf4159_web.py
```

Open **http://127.0.0.1:8765/**. The PC page uses `pluto.local` by default;
append `?host=192.168.2.1` to select another board address. Its visible
controls focus on FMCW ramps and TX2/RX2 beat capture. The CW, raw register,
RX1 measurement and status endpoints remain available through the JSON API.

The page calculates and applies a single sawtooth, continuous sawtooth or triangle ADF4159 ramp from a
start frequency, VCO span, sweep-leg time and step count. **Calculate** shows
the quantized settings and theoretical FMCW values without writing hardware;
**Apply ramp** writes the resulting registers. The raw register API also sends ordered 32-bit
hex words for advanced setups. Each word is a separate four-byte SPI transaction. Write
R1 before R0 for fractional frequency changes, and R0 last to commit
double-buffered settings. The CW API disables the ADF ramp. This API cannot
read the ADF4159 configuration back; the status endpoint only verifies SSH,
the SPI device and `xxd`. Its “last write” is a record in the running server,
so reapply settings after a board reboot or server restart.

The JSON API endpoints are:

| Endpoint | Purpose |
|---|---|
| `GET /api/status?host=pluto.local` | Check board transport and show the server's last write |
| `POST /api/cw` | Initialize R7–R0 in datasheet order and set a CW frequency |
| `POST /api/measure` | Capture and analyze RX1 near the expected RF frequency |
| `POST /api/registers` | Write raw ADF register words in the supplied order |
| `POST /api/plan`, `POST /api/ramp` | Calculate or write a ramp, including `single_sawtooth` |
| `POST /api/gate` | Read gate state, pulse TXDATA and wait for completion, or force-stop |
| `POST /api/plan` | Calculate ramp registers and theoretical values without a write |
| `POST /api/ramp` | Program a sawtooth or triangle ramp |
| `POST /api/beat` | Program the ramp and proxy one-chirp TX2/RX2 beat capture from the board CGI |
| `POST /api/stream` | Proxy newline-delimited FFT frames from repeated single sawtooth captures |
| `POST /api/tx2` | Read, affirm, or revoke the TX2 beat-capture guard |

For example, program the measured 4.5 GHz configuration:

```sh
curl -sS http://127.0.0.1:8765/api/cw \
  -H 'Content-Type: application/json' \
  -d '{"host":"pluto.local","frequency_hz":4500000000,"reference_hz":100000000,"r_counter":1,"charge_pump_code":0,"polarity":"negative","tri_state":false}'

curl -sS http://127.0.0.1:8765/api/measure \
  -H 'Content-Type: application/json' \
  -d '{"host":"pluto.local","expected_frequency_hz":4500000000}'
```

For a 50 MHz VCO sweep in 1 ms, preview then apply it with the same body:

```sh
curl -sS http://127.0.0.1:8765/api/plan \
  -H 'Content-Type: application/json' \
  -d '{"host":"192.168.2.1","start_frequency_hz":4500000000,"span_hz":50000000,"chirp_time_us":1000,"steps":200,"waveform":"sawtooth"}'
```

Send that body to `/api/ramp` to start the sweep. The reference, R divider,
charge-pump code and polarity are the same fields as `/api/cw`; their defaults
are 100 MHz, 1, 0 and negative. Set `waveform` to `triangle` for an equal down
leg, giving a full cycle of about 2 ms. The HMC586 setup restricts the VCO
sweep to 4–8 GHz, so the requested span may be up to 4 GHz but must also fit
between the selected start and 8 GHz. The planner reduces the quantized hop size if
quantization would otherwise carry it beyond 8 GHz. The AD9361 external LO
divides the VCO frequency by two.

The returned `applied` object includes the exact register words, actual span
and sweep time after ADF clock/deviation quantization, and these ideal values
for an RF sweep of bandwidth `B` over one leg of duration `T`:

| Quantity | Equation | 50 MHz VCO / 1 ms example |
|---|---|---|
| RF bandwidth | `B = B_VCO / 2` | 25 MHz |
| RF slope | `S = B / T` | 25 GHz/s |
| Reflected target delay | `τ = 2R/c` | — |
| Reflected target beat | `f_b ≈ Sτ` | 166.8 Hz per metre |
| Ideal range resolution | `ΔR = c/(2B)` | about 6 m |
| Single chirp FFT bin spacing | `Δf ≈ 1/T` | about 1 kHz |
| 30 cm one-way coax beat, velocity factor 0.667 | `f_b ≈ S·0.3/(0.667c)` | about 37.5 Hz |

The range-resolution expression describes two reflected targets separated in
distance; the one-way coax example uses a single path delay instead of a
round trip. The returned Nyquist range assumes an ideal 7.68 MSPS complex
beat stream. It does not include analog filtering, aliasing from the ramp
reset, or PLL tracking limits. The ADF4159 [ramp equations and register
definitions](https://www.analog.com/media/en/technical-documentation/data-sheets/adf4159.pdf)
are the source for the clock/deviation calculation.

**Capture beat** programs the ramp and returns one sweep leg from the selected
TX/RX pair. TX1 sends DC, so the external LO supplies its chirp; TX2 sends a
baseband chirp through the FPGA dechirp path. The FPGA marks the start and end
of the RX sweep, allowing the host to join DMA buffers and recover the sample
count. The page plots I/Q over time and a selectable-window FFT of that leg;
**Download CSV** saves the most recent one-shot samples. **Start live** opens a
streaming FFT response, and **Stop live** closes it. Capture accepts 0.4–10 ms
sweep legs, TX attenuation 35–80 dB, and RX manual gain 0–70 dB. It captures at 7.68 MSPS, so a 1 ms
leg yields 7,680 I/Q samples and an 8,192-point zero-padded FFT. The FFT bin
spacing after padding is 937.5 Hz; its physical resolving scale remains about
1 kHz. The ADF ramp and the TX baseband chirp use separate references, so the
ADF reset can fall anywhere in a captured leg. A single leg cannot resolve
the previously measured ~74 Hz ramp-added beat; use the multi-chirp method
above for that measurement.

Beat and stream requests accept `fft_window` as `"rectangular"`, `"hann"`
(default), or `"blackman_harris"`, and `discard_samples` as a nonnegative
integer no greater than one quarter of the planned chirp sample count. The
discard happens before RMS and FFT analysis and before one-shot I/Q samples
are returned. `measurement.captured_sample_count` is the gated DMA count;
`sample_count` is the analyzed count after trimming. `time_offset_us`,
`captured_time_us`, `chirp_time_us` (analyzed duration), `fft_window`, and
`window_enbw_bins` describe the result. `fft_peak_dbfs` is the peak FFT bin
normalized by the window's coherent gain, so each relative FFT bin can be
placed on a comparable dBFS scale. CSV timestamps retain the offset
from the start of the gated window. Blackman–Harris reduces distant leakage
from a strong tone, while its wider main lobe and larger equivalent noise
bandwidth can reduce sensitivity to nearby weak tones. Trimming can remove
startup transients, but also reduces observation time and frequency resolution;
neither control guarantees a higher physical SNR.

Before capture, connect the VCO output to both external LO inputs and TX2A
through the 20 dB pad to RX2A. Check that path, tick the page checkbox, and
press **Enable TX2 beat capture**. This records the same board-side affirmation
as `./devkit tx-guard affirm 1`; it does not start transmission. The page also
offers **Mute and revoke TX2** and **Refresh TX2 status**. The guard status is
stored in the board's `/tmp` and expires on reboot. The `/api/tx2` endpoint
accepts `{"action":"status"}`, `{"action":"affirm","path_confirmed":true}`,
or `{"action":"revoke"}`; add `host` for the PC server. Affirmation requires
both TX channels muted and TX DMA stopped. The CGI refuses beat capture
without the affirmation or with an active TX DMA buffer. After a reboot,
Capture beat first programs the ADF to hold the requested start frequency,
then selects both AD9361 external LO inputs and enters FDD. It configures the
radio while the VCO is steady, starts the requested ramp, and captures the
beat. The first LO transition can briefly put the AD9361 in `alert` or make
the sample-rate calibration time out; the CGI restores the saved radio state
and retries setup once while TX remains muted. It leaves the external LO
inputs selected between captures. It mutes both TX
channels before and after the cyclic probe, checks
that the TX buffer stops, and restores the previous radio settings. The ADF
ramp continues after the capture; use the CW API to stop it.

The server listens only on localhost by default. `--bind` and `--port`
change that if the page must be reached from another machine; the API has no
authentication, so keep it on a trusted network.

### Serve the page directly from Pluto

On the Buildroot firmware, use the native CGI implementation instead of the
PC Python server. From the repository root on the development PC:

```sh
tools/deploy-adf4159-board.sh 192.168.2.1
```

The [deployment script](../tools/deploy-adf4159-board.sh) cross-compiles
[`adf4159_board.c`](../tools/adf4159_board.c) with the Xilinx 2025.1 ARM
compiler and [`adf4159_probe_writer.c`](../tools/adf4159_probe_writer.c)
with the Buildroot ARM compiler and libiio. It installs an XZ-compressed CGI,
the probe writer, the TX guard helper, and a gzip-compressed HTML page in
`/mnt/jffs2/adf4159-web`, and adds a launcher to Buildroot's persistent
`/mnt/jffs2/autorun.sh`. Set `ADF4159_CC` to another compatible ARM compiler
or `ADF4159_IIO_CC` to another Buildroot compiler if needed. The launcher expands the CGI and page to `/tmp` and starts BusyBox
`httpd` on port 8080 at each boot.

Open **http://192.168.2.1:8080/**. The page detects its board-side location
and calls the local CGI service directly; no PC server or SSH session is
needed after deployment. The board-side JSON endpoints use the same request
fields and response shapes as above, with these URLs:

| Operation | Board-side URL |
|---|---|
| Status | `GET /cgi-bin/adf4159.cgi?mode=status` |
| CW settings | `POST /cgi-bin/adf4159.cgi?mode=cw` |
| RX1 measurement | `POST /cgi-bin/adf4159.cgi?mode=measure` |
| Raw registers | `POST /cgi-bin/adf4159.cgi?mode=registers` |
| Ramp preview | `POST /cgi-bin/adf4159.cgi?mode=plan` |
| Ramp write | `POST /cgi-bin/adf4159.cgi?mode=ramp` |
| One-chirp beat | `POST /cgi-bin/adf4159.cgi?mode=beat` |
| Live FFT stream | `POST /cgi-bin/adf4159.cgi?mode=stream` |
| TX2 guard | `POST /cgi-bin/adf4159.cgi?mode=tx2` |
| Ramp gate | `POST /cgi-bin/adf4159.cgi?mode=gate` |

The stream endpoint accepts the same ramp and TX2 settings as `mode=beat`,
plus `repeat_period_ms` from 100 to 10000 (default 2000). Set
`waveform` to `single_sawtooth`; each frame is one JSON object followed by a
newline, with `sequence`, `repeat_period_ms`, `trigger_interval_ms`, `applied`, `tx_probe` and
`measurement`. The stream omits I/Q arrays. Its `fft_db_relative` array keeps
native FFT bins within ±100 kHz, with `fft_min_hz` and `fft_step_hz` describing
their frequency axis. `fft_full_db_relative` is a 4,096-bin max-pooled overview
of the full sampled band, with its own `fft_full_min_hz` and
`fft_full_step_hz`. The one-shot endpoint still returns the full native FFT
and I/Q arrays. Empty lines are keepalives.
The period is a minimum TXDATA-to-TXDATA interval: capture and FFT work may
make it longer. `trigger_interval_ms` reports the measured interval (zero
for the first sweep). At stream start, the CGI programs the ADF and AD9361 once and
starts one cyclic TX DMA writer. For each sweep it verifies the TX2
affirmation and writer, enables TX2 at the requested attenuation, arms a new
RX read, pulses TXDATA, checks MUXOUT completion, then mutes TX2 before
sending the FFT frame. RX reads that have enough samples after MUXOUT done
are stopped after a validated end record; their IIO buffer is explicitly
disabled. Frames report the actual gated sample count. The cyclic TX
buffer remains enabled but TX2 is muted between sweeps. Closing the HTTP
response stops further sweeps, terminates the cyclic writer, disables DMA,
and restores the radio settings. A sweep already in progress completes its
cleanup first. The stream uses a 20-second kernel timeout for the cyclic TX
buffer and refreshes its writer after about 8 seconds. The local
`adf4159_probe_writer` checks for stop requests every 20 ms, so refreshing it
no longer waits for the stock `iio_writedev` one-second sleep. On 2026-11-19,
a 1 ms ramp at a requested 100 ms repeat period returned 50 complete frames
in 11.26 seconds: median trigger interval 216 ms, longest 263 ms at writer
refresh. One-shot HTTP captures at the same setting took 1.28–1.29 seconds
after the change, versus 2.14–2.15 seconds with the stock writer. The
one-shot endpoint still configures and restores the radio for every request;
use the stream endpoint for repeated captures.

With a 10 ms, 20,000-step, 1.5 GHz VCO-span ramp and Blackman–Harris window,
the old full-spectrum stream took about 882 ms between triggers and sent about
789 kB per frame. The compact live spectrum and cached window cut the median
interval to 329 ms and the frame to about 47 kB in a 30-sweep run. The longest
interval was 452 ms at cyclic-writer refresh; all 30 frames were complete.
The native 131,072-point FFT and ±100 kHz bins are preserved. A separate
20-sweep run had one early-ended gated frame, reported with
`complete_sample_window=false`; the framer exposes this rather than silently
padding the measurement.

The live CGI now uses a one-frame queue: the capture thread owns the ADF,
AD9361, gate, and DMA, while a worker thread performs the FFT and writes the
previous frame. Queue backpressure keeps memory bounded and preserves capture
order. On the same 10 ms, 20,000-step ramp, a 30-frame test had a 247 ms
median trigger interval, down from 329 ms before overlap. It returned 27
complete frames and three early-ended frames. One early-ended frame also
occurred in a 40-frame run with a 500 ms requested repeat period, so the
present data do not isolate the cause of short ramps. Closing the HTTP stream
discards waiting frames, joins the FFT worker, mutes TX, stops TX DMA, and
restores the radio state.

For example:

```sh
curl -N -H 'Content-Type: application/json' \
  -d '{"start_frequency_hz":4000000000,"span_hz":50000000,"chirp_time_us":1000,"steps":200,"waveform":"single_sawtooth","tx_waveform":"tone","tx_tone_frequency_hz":1000000,"repeat_period_ms":2500}' \
  'http://192.168.2.1:8080/cgi-bin/adf4159.cgi?mode=stream'
```

Close the stream with Ctrl-C. The PC proxy uses `POST /api/stream` with the
same body plus `"host":"192.168.2.1"`. The TX2 path must already be affirmed
through the 20 dB attenuator.

The live page uses a tall grayscale waterfall as its primary plot. It starts
black and draws each beat FFT as a fixed four-screen-pixel column in trigger
order. New columns enter on the right; it retains only as many beats as fit
across the current plot width, so columns never stretch as the history grows.
The page and canvas grow with the browser up to a 1600-pixel page width.
Beat number and elapsed time are shown below. The vertical
axis uses only the negative FFT bins, from zero at the top down to the selected
FFT view limit. Labels convert beat frequency to signed theoretical reflected
distance with `R = f_b c/(2S)` using the planned RF slope `S`; this is not a
calibrated range for a one-way coax path. **Waterfall average (beats)** applies
a rolling linear-power average over the last `N` frames before converting
to dB. **White level** sets the dBFS level rendered white; **display range**
sets how far below it the image becomes black. Changing FFT view or averaging
starts a fresh waterfall; level/range changes recolor the stored history.

### TXDATA-triggered single sweep and RX sample gate

The post-FIR `axis_frame` IP now wraps each gated sweep before cpack and RX
DMA. It emits the 32-bit words `F15ACAFE 53544152 sequence` (start), then
the original interleaved I/Q words, then
`F15ACAFE 454E4421 sequence sample_count xor_checksum` (end). A payload word
equal to `F15ACAFE` or `F15ACAFD` is preceded by `F15ACAFD` so neither can
be mistaken for a record. The two channels have separate framers. While the
gate is closed, a low-rate zero filler lets a partial IIO buffer complete;
the host discards filler outside frames. Ordinary bypass capture passes the
FIR output through without framing.

For single-ramp captures, the board starts `iio_readdev` with a 1024-sample
refill buffer and unlimited total count. Its parser carries state across pipe
reads, stops only after a matching end record, checks the count and checksum,
and returns precisely the IQ samples between the records. `captured_sample_count`
is therefore the actual gated sample count, independent of the IIO refill
size. Missing or damaged headers/trailers cause a capture error rather than
silently returning a partial measurement. The framer waits for the FIR tail
after MUXOUT before writing the end record.

Connect ADF4159 **MUXOUT to JP5 pin 14** (`pl_spi_miso`, FPGA H17), in addition
to TXDATA on JP5 pin 4. The 1.8 V MUXOUT connection is required to report the
actual end of a ramp. Patch 0040 packages [`axis_gate`](../firmware/hdl/axis_gate)
and puts one instance in each RX channel before the FIR and DMA. A TXDATA
rising edge opens both gates; the ADF4159 MUXOUT ramp-complete pulse closes
them. RX samples arriving while closed are discarded. The gate keeps a pending
AXI beat stable until its receiver accepts it. `adf_ramp_done` stays high
until another TXDATA trigger, software abort or FPGA reset.

Choose **Single sawtooth (TXDATA trigger)**, then **Apply ramp**. The software
sets R3's single-sawtooth burst mode, R7's TXDATA trigger enable, and R0/R4's
ramp-complete MUXOUT selection. **Trigger once** pulses GPIO line 71 and waits
for gate `done`; it does not capture samples. **Capture beat** first arms RX
DMA, then pulses TXDATA, reads the samples from that sweep, verifies `done`,
and mutes TX2. The RX framer writes an end record after the FIR tail drains;
the parser accepts sample data across any number of DMA refills. The gate
status can also be read with:

```sh
curl -sS -H 'Content-Type: application/json' -d '{"action":"status"}' \
  'http://192.168.2.1:8080/cgi-bin/adf4159.cgi?mode=gate'
```

The GPIO names are `adf_muxout` (input 76), `adf_ramp_active` (input 77),
`adf_ramp_done` (input 78), `adf_gate_abort` (output 79) and
`adf_gate_bypass` (output 80). The bypass defaults low after reset, so ordinary
continuous RX capture must hold it high; the web API does this for continuous
beat and RX1 measurement. Force-stop closes the sample gate and clears `done`,
but does not stop the ADF4159 ramp. If `done` never asserts, inspect MUXOUT wiring and
the ADF register settings before relying on the captured sweep.

Either TX waveform can be DC, a fixed tone, or the earlier
−15 to +15 MHz baseband chirp. For a fixed tone, set **TX tone frequency**
between −15 and +15 MHz relative to the external TX LO. The page defaults
to +1 MHz. The tone's number of cycles is rounded to an integer within the
cyclic TX buffer, making its phase continuous at the buffer wrap. The beat
API accepts `tx_waveform: "tone"` and signed integer
`tx_tone_frequency_hz`; `tx_probe.actual_frequency_hz` reports the rounded
value. The plain JSON API defaults to the earlier chirp when these fields are
omitted. Both TX channels are muted and DMA is closed after each capture.
On 2026-11-05, the board returned 7424 gated RX2 samples for both a +1 MHz
tone and a requested −1.234567 MHz tone (rounded to −1.235 MHz in the
61,440-sample cyclic buffer). The RX2 levels were −25.67 and −25.74 dBFS,
respectively. Both TX channels were muted and TX DMA was off afterward; the
ADF register words programmed before the test were restored.

On 2026-11-05 the new image was booted on the board. A 4.5 GHz start,
50 MHz VCO span, 200-step single sawtooth programmed for 1 ms produced a
TXDATA-to-MUXOUT gate interval of about 1007 µs in four timed trials.
Five TX2→20 dB pad→RX2 beat captures completed, each with MUXOUT `done`:
four returned 7424 samples (966.7 µs of the gate window), and one returned
6144 samples (800 µs). RX2 levels ranged from −26.58 to −26.44 dBFS. The
baseband TX probe remains cyclic and is not synchronized to TXDATA, so the
single-sweep FFT peak varied between captures; it should not be interpreted
as a stable range without synchronizing the TX reference waveform.

On 2026-11-19, the framed firmware and fixed +1 MHz TX2 tone returned 1,000
complete 1 ms single-sawtooth RX2 captures at 200 MHz VCO span. The frame
contained 7,733–7,735 samples (7,734 in 966 captures), including the gate/FIR
tail. All reported FFT peaks were in the −937.5 Hz bin; the mean RX level was
−34.15 dBFS. Control runs at 50, 100, and 200 MHz VCO span gave estimated
sub-bin beats of −220, −473, and −1,045 Hz. A 10 ms leg at 200 MHz span gave
about −100 Hz from raw I/Q phase, consistent with the tenfold smaller slope.
The slope dependence indicates an approximately 10–11 ns aggregate delay in
the current TX2/RX2 and external-LO path; its components and the connected
coax length were not independently measured. The current data cannot be used
as a cable-length calibration. Full statistics and capture data are in
[`artifacts/adf4159-tx2-1000-framed-20261119`](../artifacts/adf4159-tx2-1000-framed-20261119/README.md).

The beat API accepts `beat_shift` from 0 to 15 for both RX channels. Each
complex multiplier now outputs its full signed 33-bit I and Q products in
byte-aligned 40-bit fields. The gain stage divides by 2^(17 − `beat_shift`)
before saturating to 16-bit DMA samples. Raw RX samples use the same Q17
scale. Shift zero reproduces the former 16-bit truncation; a positive shift
can recover low product bits that were previously discarded inside the
multiplier. Four EMIO GPIO bits form
the control field (GPIO offsets 81–84); capture holds them at the requested
value and clears them when it ends. The web page exposes the same setting.
Watch `clipped_samples` for clipping at 32767 and reduce the shift if it occurs.

The polarization capture path is selected with `beat_path`: `tx1_rx1`,
`tx1_rx2`, `tx2_rx1`, or `tx2_rx2`. One TX and one RX channel are selected
for each capture. TX1 and TX2 both support a DC carrier, fixed tone or chirp
with either receiver. Each RX selects its raw external-LO beat for DC captures
or its complex multiplier result for a tone/chirp. Both multipliers use the
same selected TX stream.
Both RX channels have the signed 0–15-bit saturating `beat_shift` before
gating and DMA. The service controls the selected TX attenuation, selected
RX gain and DMA channel independently and mutes both TX outputs afterward.

Set `dual_rx: true` to capture RX1 and RX2 from one selected TX and one
TXDATA-triggered single sawtooth. Either TX can use DC, tone or chirp.
The web Beat path selector exposes this as `TX1-RX1-RX2` and `TX2-RX1-RX2`
alongside the four single-RX paths. Capture beat plots time samples and FFTs
for both RX channels; Display receiver selects the live plot and CSV channel.
The board enables all four IIO voltage channels, deinterleaves their 64-bit
DMA scans, and parses each RX start/end frame independently. The response has
`measurements.rx1` and `measurements.rx2`, each with its own sample count,
I/Q samples for one-shot capture, signal level, and FFT. Live streaming returns
the same two measurement objects per sweep without the I/Q arrays. The web
page can display either receiver while showing both channel levels, peaks,
and sample counts. `beat_shift` and `rx_gain_db` apply to both receivers in
dual mode. The previous single-RX response remains `measurement`.

The page's **Capture four beats** mode treats TX1/TX2 as circular R/L and
RX1/RX2 as linear V/H. It makes two sequential `dual_rx` single-sawtooth
captures, sharing the ramp, TX waveform, attenuation, RX gain, digital shift,
FFT window, and skipped-sample settings. It displays R→V, R→H, L→V, and L→H
range spectra. Four difference traces show H−V for each TX and R−L for each
RX in dB. Neighboring FFT-bin powers are averaged before subtraction, and a
power floor hides differences dominated by noise. Both TX guards must be
affirmed before starting; each TX is muted after its sweep.

Two color waterfalls retain one four-beat set per four-pixel time column.
The default pair shows H−V for R and L transmit separately; the selector can
show R−L for V and H receive instead. Blue is a negative dB contrast, white
is zero, red is positive, and black marks a masked or not-yet-captured bin.
The color span is adjustable. **Start polarimetric live** repeats complete
two-TX sets using the page's live repeat period; a requested period shorter
than setup and capture time runs as fast as the board permits. **Stop** lets
the current four-beat set finish, then prevents the next one. Changing FFT
view, averaging, or power floor clears the waterfall history.

The range axis uses ideal air round-trip delay. Channel gains and antenna
paths are not calibrated, and the two TX states are measured at different
times. These plots are relative power contrasts, not the calibrated
horizontal/vertical differential reflectivity and phase products defined for
[weather radar](https://www.weather.gov/jan/dualpolupgrade-products).

### Distance–angle view

The web page's **Capture distance–angle** control makes one simultaneous
`dual_rx` single-sawtooth capture with the selected TX and a DC baseband
carrier. It requires a confirmation that RX1 and RX2 now have antennas of
the **same polarization**. The existing V/H pair cannot be interpreted as a
spatial angle measurement. The capture reuses the ramp, TX attenuation, RX
gain, shared digital shift, FFT window, and skipped-sample count from the beat
controls. It checks the selected TX guard and leaves TX muted after capture.
Live streaming cannot produce this view because its response omits complex
I/Q samples.

The browser takes a windowed complex range FFT of each RX sample window and
scans angles from −90° to +90° using the two-element response
`|X1(f) + X2(f) exp(−j 2π d sin(θ)/λ)|²`. The RX2 phase calibration value is
subtracted first. Range uses negative beat frequency and the ideal air
round-trip relation `R = |f|c/(2S)`; the graph shows relative power within
50 dB of its brightest cell. If a displayed range has more than 512 FFT
bins, each heatmap row retains the strongest bin in its interval. The graph
is a single-sweep result; it does not average or track targets over time.

Set RX center spacing to **45 mm** for the planned same-polarization pair.
Choose whether RX2 sits right or left of RX1 when looking outward from the
array. Calibrate the fixed RX cable, RF and digital phase difference with a
known broadside target, then enter the observed RX2-minus-RX1 phase as the
calibration offset. At about 2.25 GHz, 260 mm is about **0.5 wavelengths**.
This is well above the half-wavelength spacing commonly used to avoid
[grating-lobe angle ambiguity](https://dev.ti.com/tirex/explore/content/radar_academy_2_10_00_2/_build/radar_academy_2_10_00_2/source/integration/antenna_design.html):
several apparent angles can give the same two-receiver phase. The heatmap
shows those lobes and does not select a unique AoA. Two receivers also cannot
resolve multiple objects at one range merely by interpolating the spatial
response. Cable delays and reflections can shift the range axis until the
receive paths are calibrated.

The shared four-bit gain control is EMIO 27–30 (GPIO offsets 81–84). EMIO 31
(GPIO 85, `rx2_raw_bypass`) now selects raw samples on **both** RX paths;
EMIO 32 (GPIO 86, `tx_reference_tx2`) selects the reference from TX2 when
high, TX1 when low. The selector forwards each TX stream to its own DAC path.
The selected reference passes through a conjugator, a 38-clock delay and a
two-output splitter before the RX multipliers. The new selector and splitter
each add one clock, retaining the prior 40-clock TX/reference offset. Four-word
FIFOs after the RX framers break the cpack cross-channel ready path without
changing captured sample data or frame markers. The 2026-11-20 local build
passed timing with +0.005 ns WNS. The revised BOOT.bin and device tree were
flashed and checksum-verified on the board on 2026-11-20. With TX2 as the
selected reference, a 4.5 GHz start, 50 MHz span, 1 ms single sawtooth and
+1 MHz TX2 tone returned 7,734 samples on each RX from one trigger. RX1 and
RX2 levels were −35.98 and −39.24 dBFS at 35 dB TX attenuation and 55 dB RX
gain. Setting the shared shift from 0 to 4 raised their levels to −12.42 and
−15.58 dBFS, respectively, with no clipped samples. Five streamed tone
sweeps each returned 7,734 samples on both RX channels. After stream close,
TX DMA was disabled, both TX attenuators read −89.75 dB, and GPIO offsets
81–86 all read zero. TX1 as the selected reference still requires a board RF
test with a confirmed load on TX1A.

With the registered RX frame FIFOs, single-RX IIO reads enable all four
voltage channels and extract the requested RX from each 64-bit DMA scan.
Selecting only one I/Q pair produced no framed data on this bitstream.
After updating the single and continuous readers, TX2 tone captures passed
for RX1 and RX2 separately (7,734 framed samples each), and a continuous
TX2→RX2 sawtooth capture returned a full 7,680-sample period.

On 2026-11-20, the updated BOOT.bin and device tree were booted and the dual
service was deployed. TX2 DC with a 4.5 GHz start, 50 MHz VCO span, 1 ms leg,
35 dB TX attenuation, 55 dB RX gain and ten discarded samples returned 7,734
framed samples on **each** RX from one trigger. Both FFT results were present;
RX1 measured −36.85 dBFS and RX2 −26.33 dBFS, with no clipped samples. A
two-frame stream also returned both 7,734-sample windows per trigger. The
TX DMA buffer was disabled and both TX attenuators read −89.75 dB after the
stream closed. These levels reflect the connected paths at the time; they do
not establish a range calibration.

The `host` JSON field is ignored by the board-side service. The web service
survives a board reboot; **ADF4159 register contents do not**, so apply the CW
settings or raw initialization sequence again after power-up. The RX1 test
restores its previous LO and gain mode. This service has no authentication and
allows register writes, so expose port 8080 only on a trusted network.
