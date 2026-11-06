#!/usr/bin/env python3
"""Measure the TX2/RX2 FPGA beat with a shared ADF4159 external LO.

Requires the 4.5 GHz HMC586 output split to both external LO inputs, both
AD9361 external LO switches already enabled, and TX2A -> 20 dB pad -> RX2A.
The board's TX2 guard affirmation is required. The transmitter is muted on
exit and the ADF4159 is returned to its measured 4.5 GHz CW configuration.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent / "selftest"))
from sdr_selftest import Board, PHY, RX, RX_LO, TX_LO  # noqa: E402
from fmcw_rx2 import chirp, start_tx2  # noqa: E402


FS = 61_440_000
DELIVERED = FS // 8
START_HZ = 4_500_000_000
STEP_COUNT = 200
CLK1 = 500
PFD_HZ = 100_000_000
DEV_OFFSET = 3
DEV = 10_486
PERIOD_S = STEP_COUNT * CLK1 / PFD_HZ


def api(mode: str, body: dict) -> dict:
    req = Request(f"http://192.168.2.1:8080/cgi-bin/adf4159.cgi?mode={mode}",
                  json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urlopen(req, timeout=15) as response:
        return json.load(response)


def ramp_words(dev: int = DEV) -> list[str]:
    # ADF4159 Rev. B: R6 step count, R5 signed DEV and offset, R4 ramp timer,
    # R3 continuous sawtooth, R2 CLK1 and reference divider, R0 ramp enable.
    # Bank 1 remains disabled but is initialized for a reproducible startup.
    words = [
        0x00000007,
        (STEP_COUNT << 3) | 6, 0x00800006,
        (DEV_OFFSET << 19) | (dev << 3) | 5, 0x00800005,
        0x00180000 | (1 << 7) | 4,
        0x00180000 | (1 << 7) | 0x40 | 4,
        0x00020003,  # DB17=1 per register map; negative PD polarity
        0x0000800A | (CLK1 << 3),  # R=1, CP code 0
        0x00000001,
        0xB0168000,  # 4.5 GHz N=45, digital lock MUX, ramp enabled
    ]
    return [f"0x{x:08X}" for x in words]


def metrics(samples: np.ndarray, period_samples: int) -> dict:
    # Report absolute level and the phase slope in a fixed interval after
    # the TX baseband-chirp reset. ADF ramp reset can fall elsewhere; choosing
    # a different window for CW and ramp creates a false frequency change.
    z = samples.astype(np.complex128)
    rms = float(np.sqrt(np.mean(np.abs(z) ** 2)))
    folds = len(z) // period_samples
    stacked = z[:folds * period_samples].reshape(folds, period_samples)
    folded = np.mean(stacked, axis=0)
    # Find the TX reset from its deep amplitude notch, then smooth phase and
    # fit the early 10-40% of that period, clear of TX RF DC crossing at 50%.
    reset = int(np.argmin(np.abs(folded)))
    folded = np.roll(folded, -reset)
    window = 128
    smooth = np.convolve(np.r_[folded[-window:], folded, folded[:window]],
                         np.ones(window) / window, mode="same")[window:-window]
    indices = np.arange(int(.10 * period_samples), int(.40 * period_samples))
    phase = np.unwrap(np.angle(smooth[indices]))
    phase -= phase.mean()
    t = np.arange(len(phase)) / DELIVERED
    slope_rad_s = float(np.polyfit(t, phase, 1)[0])
    fit = np.polyval(np.polyfit(t, phase, 1), t)
    residual = float(np.sqrt(np.mean((phase - fit) ** 2)))
    return {
        "sample_count": len(samples), "sample_rate_hz": DELIVERED,
        "rms_dbfs": round(20 * np.log10(max(rms, 1e-9) / 2048), 2),
        "peak_adc_counts": int(np.max(np.maximum(np.abs(z.real), np.abs(z.imag)))),
        "folded_periods": folds, "tx_reset_sample": reset,
        "fit_interval_ms": [0.1 * period_samples / DELIVERED * 1000,
                            0.4 * period_samples / DELIVERED * 1000],
        "early_window_beat_hz_signed": round(slope_rad_s / (2 * np.pi), 2),
        "phase_fit_residual_rad": round(residual, 4),
        "folded_phase_change_deg": round(np.degrees(phase[-1] - phase[0]), 2),
    }


def added_beat(cw: np.ndarray, ramp: np.ndarray, period_samples: int) -> dict:
    """Find the ramp-only phase slope between the two loopback captures.

    The ADF and AD9361 use independent clocks, so their sawtooth resets have
    arbitrary relative phase. Comparing one fixed interval can straddle the
    ADF reset. Instead, fit short local phase differences over the whole TX
    period and take the dominant negative slope; the positive reset transient
    is excluded. The sign is RX2 times conjugated TX2 on this FPGA build.
    """
    folded = {}
    for name, samples in (("cw", cw), ("ramp", ramp)):
        periods = len(samples) // period_samples
        signal = samples[:periods * period_samples].reshape(periods, period_samples)
        mean = signal.mean(axis=0)
        folded[name] = np.roll(mean, -int(np.argmin(np.abs(mean))))
    ratio = folded["ramp"] * np.conj(folded["cw"])
    ratio /= np.maximum(np.abs(ratio), 1e-10)
    lag = period_samples // 10  # 0.1 ms at the default rate
    local_hz = (np.angle(ratio[lag:] * np.conj(ratio[:-lag])) *
                DELIVERED / (2 * np.pi * lag))
    fraction = np.arange(len(local_hz)) / period_samples
    valid = ((fraction > .05) & (fraction < .88) &
             ~((fraction > .42) & (fraction < .58)))
    values = local_hz[valid]
    bins = np.arange(-300, 1, 10)
    counts, edges = np.histogram(values, bins=bins)
    center = (edges[np.argmax(counts)] + edges[np.argmax(counts) + 1]) / 2
    selected = values[(values > center - 15) & (values < center + 15)]
    if len(selected) < 100:
        raise RuntimeError("no stable negative ramp beat found")
    return {
        "beat_hz_signed": round(float(np.median(selected)), 2),
        "local_spread_hz": round(float(np.std(selected)), 2),
        "local_samples": len(selected),
        "method": "mode of 0.1-ms local phase slopes of ramp/CW, excluding TX reset and DC crossing",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        default=Path("artifacts/adf4159-ramp-beat"))
    parser.add_argument("--tx-atten", type=float, default=-35.0)
    parser.add_argument("--rx-gain", type=float, default=55.0)
    parser.add_argument("--capture-samples", type=int, default=262_144)
    parser.add_argument("--deviation-word", type=int, default=DEV,
                        help="ADF R5 DEV word; 10486 gives 50 MHz VCO span, 5243 gives 25 MHz")
    args = parser.parse_args()
    if not -80 <= args.tx_atten <= -35:
        parser.error("TX2 attenuation must be between -80 and -35 dB")
    if args.capture_samples < 32_768 or args.capture_samples % 8:
        parser.error("capture-samples must be >=32768 and divisible by 8")
    if not 1 <= args.deviation_word <= 32_767:
        parser.error("deviation-word must be a positive signed 16-bit value")
    args.output.mkdir(parents=True, exist_ok=True)
    board = Board(timeout=30)
    board.save_state()
    rx2_old_mode = board.rd(PHY, "voltage1", "gain_control_mode")
    rx2_old_gain = board.rd(PHY, "voltage1", "hardwaregain")
    tx_old_bw = board.rd(PHY, "voltage0", "rf_bandwidth", True)
    rx_ext = board.rd(PHY, RX_LO, "external", True)
    tx_ext = board.rd(PHY, TX_LO, "external", True)
    ensm_old = board.rd_dev(PHY, "ensm_mode")
    captured = {}
    try:
        if not board.mute_tx():
            raise RuntimeError("cannot prove both transmitters muted")
        if rx_ext != "1" or tx_ext != "1" or ensm_old != "fdd":
            raise RuntimeError("both external LO switches must already be 1 with AD9361 in FDD")
        api("cw", {"frequency_hz": START_HZ})
        board.wr(PHY, RX_LO, "frequency", START_HZ // 2, True)
        board.wr(PHY, TX_LO, "frequency", START_HZ // 2, True)
        board.wr(PHY, "voltage0", "sampling_frequency", FS)
        board.wr(PHY, "voltage0", "rf_bandwidth", 30_000_000)
        board.wr(PHY, "voltage0", "rf_bandwidth", 30_000_000, True)
        board.wr(PHY, "voltage1", "gain_control_mode", "manual")
        board.wr(PHY, "voltage1", "hardwaregain", args.rx_gain)
        board.wr_dev(RX, "in_voltage_sampling_frequency", DELIVERED)
        if abs(float(board.rd_dev(RX, "in_voltage_sampling_frequency")) - DELIVERED) > 1:
            raise RuntimeError("FPGA beat /8 decimator did not engage")
        if board.rd(PHY, RX_LO, "external", True) != "1" or board.rd(PHY, TX_LO, "external", True) != "1":
            raise RuntimeError("external LO did not enable on both mixers")
        if board.rd_dev(PHY, "ensm_mode") != "fdd":
            raise RuntimeError("AD9361 did not enter FDD after external LO selection")
        rf_center = START_HZ // 2
        tx_iq = chirp(FS, rf_center - 15_000_000, rf_center + 15_000_000,
                      rf_center, 61_440, 16_000)
        start_tx2(board, tx_iq, args.tx_atten)
        if board.rdf(PHY, "voltage1", "hardwaregain", True) > args.tx_atten + 0.26:
            raise RuntimeError("TX2 attenuation readback too high")
        print(f"TX2 baseband chirp +/-15 MHz, TX2 {args.tx_atten:g} dB, "
              f"RX2 {args.rx_gain:g} dB", flush=True)
        period_samples = round(PERIOD_S * DELIVERED)
        for mode in ("cw", "ramp"):
            if mode == "ramp":
                answer = api("registers", {"words": ramp_words(args.deviation_word)})
                if len(answer.get("written", [])) != len(ramp_words(args.deviation_word)):
                    raise RuntimeError(f"short SPI register write: {answer}")
            board.capture(65_536, 1)  # discard pre-switch DMA data
            raw = np.asarray(board.capture(args.capture_samples, 1),
                             dtype=np.complex64)
            if len(raw) != args.capture_samples:
                raise RuntimeError(f"RX2 short capture: {len(raw)} samples")
            if float(np.sqrt(np.mean(np.abs(raw) ** 2))) < 50:
                raise RuntimeError("RX2 beat below 50 counts RMS; refusing a weak-signal estimate")
            captured[mode] = raw
            print(f"{mode}: {metrics(raw, period_samples)}", flush=True)
        np.savez_compressed(args.output / "rx2_beat_iq.npz", **captured)
        step_hz = PFD_HZ * args.deviation_word * (1 << DEV_OFFSET) / (1 << 25)
        span_hz = step_hz * STEP_COUNT
        cw_metrics = metrics(captured["cw"], period_samples)
        ramp_metrics = metrics(captured["ramp"], period_samples)
        differential = added_beat(captured["cw"], captured["ramp"], period_samples)
        added_beat_hz = differential["beat_hz_signed"]
        print(f"Ramp-added beat: {added_beat_hz:+.2f} Hz; "
              f"effective delay {-added_beat_hz / (span_hz / (2 * PERIOD_S)) * 1e9:.2f} ns", flush=True)
        report = {
            "captured_utc": datetime.now(timezone.utc).isoformat(),
            "vco_start_hz": START_HZ, "vco_span_hz": span_hz,
            "rf_start_hz": START_HZ / 2, "rf_span_hz": span_hz / 2,
            "ramp_period_s": PERIOD_S, "vco_step_hz": step_hz,
            "register_words": ramp_words(args.deviation_word),
            "tx_baseband_chirp_hz": [-15_000_000, 15_000_000],
            "tx_atten_db": args.tx_atten, "rx_gain_db": args.rx_gain,
            "cw": cw_metrics, "ramp": ramp_metrics,
            "ramp_added_beat": differential,
            "estimated_ramp_beat_hz_signed": round(
                cw_metrics["early_window_beat_hz_signed"] + added_beat_hz, 2),
            "effective_delay_from_added_beat_ns": round(
                -added_beat_hz / (span_hz / (2 * PERIOD_S)) * 1e9, 3),
        }
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Saved {args.output / 'report.json'}", flush=True)
    finally:
        try:
            if not board.tx_stop():
                print("TX mute was not verified", file=sys.stderr)
            api("cw", {"frequency_hz": START_HZ})
            board.restore_state()
            if rx2_old_mode == "manual":
                board.wr(PHY, "voltage1", "hardwaregain", rx2_old_gain)
            board.wr(PHY, "voltage1", "gain_control_mode", rx2_old_mode)
            board.wr(PHY, "voltage0", "rf_bandwidth", tx_old_bw, True)
            if ensm_old == "fdd" and board.rd_dev(PHY, "ensm_mode") != "fdd":
                board.wr_dev(PHY, "ensm_mode", "fdd")
                if board.rd_dev(PHY, "ensm_mode") != "fdd":
                    raise RuntimeError("AD9361 remained in ALERT after LO restoration")
        finally:
            board.c.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
