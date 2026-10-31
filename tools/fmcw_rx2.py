#!/usr/bin/env python3
"""Transmit 1000-2000 MHz FMCW on TX2 and capture FPGA-dechirped RX2.

The AD9361 TX filter cannot pass a 1 GHz instantaneous chirp. Overlapping
32 MHz subchirps, with 20 MHz shared RF band between neighbours, cover the
requested range. TX and RX LOs move together between segments. Phase/delay
calibration transfers one beat phase reference across the stitched sweep.
Results include a self-contained interactive HTML dashboard. A local TX2/RX2
path-calibration JSON adds a calibrated one-way coax-distance chart.

Run with TX2A -> >=20 dB attenuator -> RX2A connected and TX2 affirmed:
    ./devkit tx-guard affirm 1
    .venv/bin/python tools/fmcw_rx2.py --output artifacts/fmcw-rx2-1000-2000 --resume

Dependencies: numpy, matplotlib, plotly. Radio access uses the repo's minimal IIOD
client, so pyadi-iio is not required. Both transmitters are muted on exit.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent / "selftest"))
from iiod_min import mask_for  # noqa: E402
from sdr_selftest import Board, PHY, RX, TX, RX_LO, TX_LO, pack_tx_scan  # noqa: E402
from fmcw_phase import recover_phase, plot_phase  # noqa: E402
from fmcw_path_calibration import LIGHT_SPEED_M_PER_S, measure_profiles, phase_delay_ns  # noqa: E402
from fmcw_interactive import (beat_overview_indices, distance_profile,
                              low_pass_range, save_interactive)  # noqa: E402


FS = 61_440_000
DECIMATION = 8
DELIVERED = FS // DECIMATION
RF_START = 1_000_000_000
RF_STOP = 2_000_000_000
SUBCHIRP_SPAN = 32_000_000
OVERLAP = 20_000_000
TX_RF_BW = 36_000_000
RX_RF_BW = 36_000_000
QUIET = -89.75
DEFAULT_CALIBRATION = Path("artifacts/fmcw-rx2-path-calibration.json")


def load_calibration(path: Path) -> dict:
    calibration = json.loads(path.read_text())
    for field in ("fixed_path_delay_ns_median", "coax_delay_ns_per_meter",
                  "short_length_m", "long_length_m", "matches"):
        if field not in calibration:
            raise ValueError(f"{path} lacks calibration field {field}")
    if (not calibration["matches"] or
            not np.isfinite(calibration["fixed_path_delay_ns_median"]) or
            not np.isfinite(calibration["coax_delay_ns_per_meter"]) or
            calibration["coax_delay_ns_per_meter"] <= 0):
        raise ValueError(f"{path} contains an invalid path calibration")
    return calibration


def plan_segments(start: int, stop: int, span: int, overlap: int) -> list[tuple[int, int]]:
    """Cover [start, stop] with adjacent overlaps of exactly ``overlap`` Hz."""
    if not (70_000_000 <= start < stop <= 6_000_000_000):
        raise ValueError("RF bounds must be ordered and inside the AD9361 LO range")
    if not (0 < overlap < span <= 32_000_000):
        raise ValueError("need 0 < overlap < subchirp span <= 32 MHz")
    if stop - start < span:
        return [(start, stop)]
    result = []
    low = start
    while True:
        high = min(low + span, stop)
        result.append((low, high))
        if high == stop:
            return result
        low = high - overlap


def chirp(fs: int, low: int, high: int, lo: int, samples: int, amplitude: int) -> np.ndarray:
    """A cyclic, approximately linear IQ ramp with a tapered reset seam."""
    inst = low - lo + (high - low) * np.arange(samples, dtype=np.float64) / samples
    # Make the sum of sample-to-sample phase advances an integer number of turns.
    inst += (round(inst.sum() / fs) * fs - inst.sum()) / samples
    phase = 2 * np.pi * np.cumsum(np.r_[0.0, inst[:-1]]) / fs
    env = np.ones(samples, dtype=np.float64)
    edge = max(16, samples // 100)
    ramp = np.sin(np.linspace(0, np.pi / 2, edge, endpoint=False)) ** 2
    env[:edge] = ramp
    env[-edge:] = ramp[::-1]
    return amplitude * env * np.exp(1j * phase)


def start_tx2(board: Board, iq: np.ndarray, attenuation: float) -> None:
    did, total = board.dev[TX]
    board.buffer_enable_is_a_raise(1, True)  # gate before enabling DMA
    if not board.mute_tx():
        raise RuntimeError("TX attenuation could not be verified at mute")
    board.c.close_buffer(did)
    values = pack_tx_scan(iq, 1, total)
    board.c.write_samples(did, values, mask_for(range(total), total),
                          nchannels=total, cyclic=True)
    board.assert_still_muted("FMCW buffer enable")
    board.set_tx_atten(attenuation, 1)
    measured = board.rdf(PHY, "voltage1", "hardwaregain", True)
    other = board.rdf(PHY, "voltage0", "hardwaregain", True)
    if abs(measured - attenuation) > 0.5 or other > QUIET + 0.26:
        raise RuntimeError(f"TX attenuation mismatch: TX1={other}, TX2={measured}")


def acquire_segment(board: Board, low: int, high: int, args: argparse.Namespace) -> dict:
    lo = (low + high) // 2
    board.tx_stop()
    board.wr(PHY, RX_LO, "frequency", lo, True)
    board.wr(PHY, TX_LO, "frequency", lo, True)
    actual_rx_lo = board.rdf(PHY, RX_LO, "frequency", True)
    actual_tx_lo = board.rdf(PHY, TX_LO, "frequency", True)
    if abs(actual_rx_lo - lo) > 100 or abs(actual_tx_lo - lo) > 100:
        raise RuntimeError(f"LO readback differs from {lo}: RX={actual_rx_lo}, TX={actual_tx_lo}")
    iq = chirp(FS, low, high, lo, args.chirp_samples, args.amplitude)
    print(f"TX2 {low / 1e6:.1f}-{high / 1e6:.1f} MHz, LO {lo / 1e6:.2f} MHz, "
          f"{len(iq) / FS * 1e3:.3f} ms/chirp", flush=True)
    start_tx2(board, iq, args.tx_atten)
    try:
        # The first RX DMA block may contain pre-start data or FIR transients.
        board.capture(args.capture_samples, 1)
        raw = board.capture(args.capture_samples, 1)
        data = np.asarray(raw, dtype=np.complex64)
    finally:
        if not board.tx_stop():
            raise RuntimeError("could not verify TX mute after capture")
    if data.size != args.capture_samples:
        raise RuntimeError(f"RX2 returned {data.size} samples, expected {args.capture_samples}")
    if not np.any(data):
        raise RuntimeError("RX2 DMA returned only zeros")
    return {"lo_hz": lo, "rf_low_hz": low, "rf_high_hz": high,
            "tx_atten_db": args.tx_atten, "rx_gain_db": args.rx_gain,
            "adc_rate_hz": FS, "rx2_rate_hz": DELIVERED,
            "chirp_samples": args.chirp_samples,
            "samples": data}


def plot(segments: list[dict], output: Path) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    show = sorted(set((0, len(segments) // 2, len(segments) - 1)))
    fig, axes = plt.subplots(len(show), 2, figsize=(13, 3.4 * len(show)),
                             layout="constrained")
    axes = np.atleast_2d(axes)
    for row, index in enumerate(show):
        result = segments[index]
        x = result["samples"]
        rate = result["rx2_rate_hz"]
        title = (f"TX2 segment {index + 1}/{len(segments)}: "
                 f"{result['rf_low_hz'] / 1e6:.1f}–{result['rf_high_hz'] / 1e6:.1f} MHz → RX2 beat")
        nshow = min(len(x), int(0.25e-3 * rate))
        t = np.arange(nshow) / rate * 1e3
        axes[row, 0].plot(t, x.real[:nshow], lw=0.7, label="I")
        axes[row, 0].plot(t, x.imag[:nshow], lw=0.7, label="Q")
        axes[row, 0].set(title=title, xlabel="Time (ms)", ylabel="RX2 DMA counts")
        axes[row, 0].legend(loc="upper right")
        axes[row, 0].grid(alpha=0.25)

        y = x - x.mean()
        spectrum = np.fft.fftshift(np.fft.fft(y * np.hanning(len(y))))
        freq = np.fft.fftshift(np.fft.fftfreq(len(y), 1 / rate))
        db = 20 * np.log10(np.maximum(np.abs(spectrum), 1e-12) / (len(y) / 2))
        keep = np.abs(freq) <= 100_000
        axes[row, 1].plot(freq[keep] / 1e3, db[keep], lw=0.8)
        axes[row, 1].set(title="Dechirped RX2 spectrum (DC removed)",
                         xlabel="Beat frequency (kHz)", ylabel="Amplitude (dB re DMA count)")
        axes[row, 1].grid(alpha=0.25)
    fig.savefig(output / "rx2_time_frequency.png", dpi=160)
    plt.close(fig)


def plot_concatenated(beat: np.ndarray, time_s: np.ndarray, rate: float,
                      output: Path, max_range_m: float | None = None) -> float:
    """Show the virtual wideband beat in time and frequency; return peak Hz."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    centered = beat - beat.mean()
    spectrum = np.fft.fftshift(np.fft.fft(centered * np.hanning(len(centered))))
    frequencies = np.fft.fftshift(np.fft.fftfreq(len(centered), 1 / rate))
    band = np.abs(frequencies) <= 100_000
    peak = float(frequencies[np.flatnonzero(band)[np.argmax(np.abs(spectrum[band]))]])
    db = 20 * np.log10(np.maximum(np.abs(spectrum), 1e-12) / (len(centered) / 2))
    fig, axes = plt.subplots(3, 1, figsize=(13, 9), layout="constrained")
    short = time_s <= time_s[0] + 0.3e-3
    axes[0].plot(time_s[short] * 1e3, beat.real[short], lw=0.7, label="I")
    axes[0].plot(time_s[short] * 1e3, beat.imag[short], lw=0.7, label="Q")
    filter_label = (f" ({max_range_m:g} m low-pass)"
                    if max_range_m is not None else "")
    axes[0].set(title="Phase-referenced concatenated RX2 beat" +
                filter_label + ": first 0.3 ms",
                xlabel="Virtual sweep time (ms)", ylabel="RX2 DMA counts")
    axes[0].legend()
    stride = max(1, len(beat) // 12000)
    axes[1].plot(time_s[::stride] * 1e3, np.abs(beat[::stride]), lw=0.6)
    axes[1].set(title="Beat magnitude across the full RF sweep",
                xlabel="Virtual sweep time (ms)", ylabel="Magnitude (DMA counts)")
    axes[2].plot(frequencies[band] / 1e3, db[band], lw=0.7)
    axes[2].set(title=f"Full beat spectrum{filter_label}; strongest bin {peak / 1e3:+.2f} kHz",
                xlabel="Beat frequency (kHz)", ylabel="Amplitude (dB re DMA count)")
    for axis in axes:
        axis.grid(alpha=0.25)
    fig.savefig(output / "rx2_beat_concatenated.png", dpi=160)
    plt.close(fig)
    return peak


def plot_full_beat(beat: np.ndarray, time_s: np.ndarray, output: Path,
                   raw_beat: np.ndarray | None = None,
                   max_range_m: float = 100.0) -> Path:
    """Save I, Q and magnitude over the complete virtual sweep."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    full = beat_overview_indices(len(beat))
    time_ms = time_s[full] * 1e3
    fig, axes = plt.subplots(2, 1, figsize=(14, 7.5), sharex=True,
                             layout="constrained")
    axes[0].plot(time_ms, beat.real[full], lw=0.6, label="I")
    axes[0].plot(time_ms, beat.imag[full], lw=0.6, label="Q")
    axes[0].set(title="Full phase-referenced virtual beat I/Q"
                + (f" ({max_range_m:g} m low-pass)" if raw_beat is not None else ""),
                ylabel="RX2 DMA counts")
    axes[0].legend(loc="upper right")
    if raw_beat is not None:
        axes[1].plot(time_ms, np.abs(raw_beat[full]), lw=0.5,
                     color="#a8acb1", label="Before filter")
    axes[1].plot(time_ms, np.abs(beat[full]), lw=0.6, color="#23856b",
                 label="After filter" if raw_beat is not None else None)
    if raw_beat is not None:
        axes[1].legend(loc="upper right")
    axes[1].set(xlabel="Virtual sweep time (ms)",
                ylabel="Magnitude (DMA counts)")
    for axis in axes:
        axis.grid(alpha=0.25)
    path = output / "rx2_beat_full_signal.png"
    fig.savefig(path, dpi=160)
    plt.close(fig)
    return path


def save_results(results: list[dict], output: Path, captured_utc: str | None = None,
                 calibration: dict | None = None, calibration_path: Path | None = None,
                 distance_medium: str = "coax", air_refractive_index: float = 1.0003,
                 max_range_m: float = 100.0) -> int:
    """Analyze one capture set and save reproducible raw, calibrated, and plotted data."""
    output.mkdir(parents=True, exist_ok=True)
    for result in results:
        x = result["samples"]
        y = x - x.mean()
        spectrum = np.fft.fftshift(np.fft.fft(y * np.hanning(len(y))))
        frequency = np.fft.fftshift(np.fft.fftfreq(len(y), 1 / DELIVERED))
        in_band = np.abs(frequency) <= 100_000
        peak_index = np.flatnonzero(in_band)[np.argmax(np.abs(spectrum[in_band]))]
        result["rx2_rms_counts"] = float(np.sqrt(np.mean(np.abs(x) ** 2)))
        result["rx2_peak_counts"] = float(np.abs(x).max())
        result["beat_peak_hz"] = float(frequency[peak_index])
    capture_time = captured_utc or datetime.now(timezone.utc).isoformat()
    # Preserve the raw board capture even if a later phase fit fails.
    np.savez_compressed(output / "rx2_beat.npz", **{
        f"segment_{i + 1}": r["samples"] for i, r in enumerate(results)})
    base_meta = {"captured_utc": capture_time,
                 "description": "TX2 segmented FMCW, FPGA conjugate/CMPY beat captured on RX2 DMA",
                 "segments": [{k: v for k, v in r.items() if k != "samples"} for r in results]}
    (output / "metadata.json").write_text(json.dumps(base_meta, indent=2) + "\n")
    profiles, calibrations, closure, stitched = recover_phase(results)
    covered = np.flatnonzero(stitched["valid"])
    if not np.all(stitched["valid"][covered[0]:covered[-1] + 1]):
        raise ValueError("phase-referenced beat has an uncovered RF gap")
    frequency_hz = stitched["frequency_hz"][covered[0]:covered[-1] + 1]
    beat = stitched["response"][covered[0]:covered[-1] + 1]
    first_span = results[0]["rf_high_hz"] - results[0]["rf_low_hz"]
    virtual_slope = first_span * FS / results[0]["chirp_samples"]
    time_s = (frequency_hz - frequency_hz[0]) / virtual_slope
    virtual_rate = virtual_slope / (frequency_hz[1] - frequency_hz[0])
    range_profile = None
    measurement = None
    stitched_delay_correction_ns = None
    calibration_in_band = True
    filtered_beat = beat
    filter_info = None
    if calibration is not None:
        matched_windows = calibration["matches"]
        calibration_in_band = any(
            int(result["rf_low_hz"]) == int(match["rf_low_hz"])
            and int(result["rf_high_hz"]) == int(match["rf_high_hz"])
            for result in results for match in matched_windows)
        indexed_profiles = {
            (int(result["rf_low_hz"]), int(result["rf_high_hz"]),
             int(result["chirp_samples"]), int(result["rx2_rate_hz"])): profile
            for result, profile in zip(results, profiles)
        }
        if distance_medium == "coax":
            try:
                measurement = measure_profiles(indexed_profiles, calibration)
            except ValueError as exc:
                print(f"Calibrated raw-window length unavailable: {exc}")
        range_beat = beat
        if measurement is not None:
            strong = np.abs(beat) >= 0.2 * np.median(np.abs(beat))
            stitched_delay_ns, _ = phase_delay_ns(frequency_hz, beat, strong)
            target_delay_ns = (float(calibration["fixed_path_delay_ns_median"]) +
                               float(calibration["coax_delay_ns_per_meter"]) *
                               measurement["estimated_length_m_median"])
            stitched_delay_correction_ns = target_delay_ns - stitched_delay_ns
            range_beat = beat * np.exp(-2j * np.pi * (frequency_hz - frequency_hz[0]) *
                                      stitched_delay_correction_ns * 1e-9)
        propagation_delay_ns_per_meter = (float(calibration["coax_delay_ns_per_meter"])
                                          if distance_medium == "coax" else
                                          2e9 * air_refractive_index / LIGHT_SPEED_M_PER_S)
        filtered_beat, filter_info = low_pass_range(
            range_beat, virtual_rate, virtual_slope,
            float(calibration["fixed_path_delay_ns_median"]),
            propagation_delay_ns_per_meter, max_range_m)
        range_profile = distance_profile(
            filtered_beat, virtual_rate, virtual_slope, frequency_hz[-1] - frequency_hz[0],
            float(calibration["fixed_path_delay_ns_median"]),
            propagation_delay_ns_per_meter, max_range_m)
    beat_peak = plot_concatenated(filtered_beat, time_s, virtual_rate, output,
                                  max_range_m if filter_info is not None else None)
    full_beat_plot = plot_full_beat(filtered_beat, time_s, output,
                                    beat if filter_info is not None else None,
                                    max_range_m)
    meta = {**base_meta,
            "segments": [{**base_meta["segments"][i],
                          "seam_sample": profiles[i]["seam_sample"],
                          "coherent_chirps": profiles[i]["coherent_chirps"]}
                         for i in range(len(results))],
            "phase_recovery": {"method": "weighted complex overlap phase and delay referencing",
                               "pairs": calibrations, "triple_overlap_closure": closure},
            "concatenated_beat": {"virtual_sweep": True,
                                  "samples": int(len(beat)),
                                  "first_rf_hz": float(frequency_hz[0]),
                                  "last_rf_hz": float(frequency_hz[-1]),
                                  "frequency_step_hz": float(frequency_hz[1] - frequency_hz[0]),
                                  "virtual_sweep_duration_s": float(time_s[-1]),
                                  "virtual_sample_rate_hz": float(virtual_rate),
                                  "strongest_beat_bin_hz": beat_peak,
                                  "range_low_pass": filter_info}}
    if range_profile is not None:
        meta["calibrated_distance"] = {
            "calibration_file": str(calibration_path),
            "calibration_short_captured_utc": calibration.get("short_captured_utc"),
            "calibration_long_captured_utc": calibration.get("long_captured_utc"),
            "fixed_path_delay_ns": calibration["fixed_path_delay_ns_median"],
            "coax_delay_ns_per_meter": calibration["coax_delay_ns_per_meter"],
            "medium": distance_medium,
            "air_refractive_index": air_refractive_index if distance_medium == "air" else None,
            "propagation_delay_ns_per_meter": propagation_delay_ns_per_meter,
            "propagation_legs": 2 if distance_medium == "air" else 1,
            "calibration_in_measured_rf_band": calibration_in_band,
            "absolute_range_verified": measurement is not None,
            "fft_peak_distance_cm": range_profile["fft_peak_distance_cm"],
            "fft_display_step_cm": range_profile["display_step_cm"],
            "distance_resolution_cm": range_profile["distance_resolution_cm"],
            "stitched_delay_correction_ns": stitched_delay_correction_ns,
            "raw_subchirp_phase_fit": measurement}
    (output / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n")
    np.savez_compressed(output / "rx2_phase_stitched.npz",
                        frequency_hz=stitched["frequency_hz"],
                        complex_response=stitched["response"], valid=stitched["valid"])
    np.savez_compressed(output / "rx2_beat_concatenated.npz", beat=beat,
                        frequency_hz=frequency_hz, time_s=time_s,
                        virtual_sample_rate_hz=virtual_rate)
    if filter_info is not None:
        np.savez_compressed(output / "rx2_beat_filtered.npz", beat=filtered_beat,
                            frequency_hz=frequency_hz, time_s=time_s,
                            virtual_sample_rate_hz=virtual_rate,
                            max_range_m=max_range_m)
    else:
        (output / "rx2_beat_filtered.npz").unlink(missing_ok=True)
    if range_profile is not None:
        np.savez_compressed(output / "rx2_distance_profile.npz",
                            distance_cm=range_profile["distance_cm"],
                            relative_db=range_profile["relative_db"],
                            fft_peak_distance_cm=range_profile["fft_peak_distance_cm"],
                            display_step_cm=range_profile["display_step_cm"],
                            distance_resolution_cm=range_profile["distance_resolution_cm"])
    else:
        (output / "rx2_distance_profile.npz").unlink(missing_ok=True)
    plot(results, output)
    plot_phase(profiles, calibrations, closure, stitched, output)
    interactive = save_interactive(results, stitched, calibrations, closure,
                                   filtered_beat, frequency_hz, time_s, virtual_rate,
                                   output, capture_time, range_profile, measurement,
                                   str(calibration_path) if calibration_path else None,
                                   distance_medium, air_refractive_index, calibration_in_band,
                                   filter_info)
    if len(results) > 10:
        rms = np.array([r["rx2_rms_counts"] for r in results])
        print(f"Captured {len(results)} segments: RX2 RMS {rms.min():.1f}–{rms.max():.1f} "
              f"counts ({rms.mean():.1f} mean)")
    else:
        for i, r in enumerate(results, 1):
            x = r["samples"]
            print(f"Segment {i}: {len(x)} RX2 samples, RMS {np.sqrt(np.mean(np.abs(x)**2)):.1f} "
                  f"counts, peak {np.abs(x).max():.0f} counts")
    print(f"Saved {output / 'rx2_time_frequency.png'}")
    if len(calibrations) > 10:
        after = np.array([cal["residual_rms_deg"] for cal in calibrations])
        coherence = np.array([cal["coherence_after"] for cal in calibrations])
        print(f"Phase recovery: {len(calibrations)} overlaps, residual "
              f"{after.mean():.2f}° mean / {after.max():.2f}° worst RMS, "
              f"minimum coherence {coherence.min():.5f}")
    else:
        for cal in calibrations:
            print(f"Phase {cal['reference_segment']}→{cal['target_segment']}: "
                  f"{cal['phase_correction_rad']:+.3f} rad at "
                  f"{cal['phase_reference_hz'] / 1e6:.3f} MHz, "
                  f"delay correction {cal['differential_delay_ns']:+.3f} ns, "
                  f"RMS {cal['mismatch_before_rms_deg']:.2f}°→{cal['residual_rms_deg']:.2f}°")
    if closure:
        print(f"Triple-overlap closure: {closure['rms_phase_deg']:.2f}° RMS, "
              f"{closure['max_abs_phase_deg']:.2f}° maximum across {closure['count']} triples")
    print(f"Concatenated beat: {len(beat)} complex samples, "
          f"{frequency_hz[0] / 1e6:.3f}–{frequency_hz[-1] / 1e6:.3f} MHz, "
          f"{time_s[-1] * 1e3:.2f} ms virtual sweep, peak {beat_peak / 1e3:+.2f} kHz")
    print(f"Saved {output / 'rx2_phase_recovery.png'}")
    print(f"Saved {output / 'rx2_beat_concatenated.png'}")
    print(f"Saved {full_beat_plot}")
    if filter_info is not None:
        print(f"Applied {max_range_m:g} m low-pass: full pass through "
              f"{filter_info['pass_range_m']:g} m; stop at "
              f"{filter_info['stop_frequency_hz'] / 1e3:.2f} kHz")
        print(f"Saved {output / 'rx2_beat_filtered.npz'}")
    if range_profile is not None:
        if measurement:
            print(f"Calibrated cable length: "
                  f"{measurement['estimated_length_m_median'] * 100:.1f} cm "
                  f"from {measurement['matched_subchirps']} raw subchirps; "
                  f"range resolution about {range_profile['distance_resolution_cm']:.1f} cm")
        else:
            print(f"Estimated {distance_medium} range FFT peak: "
                  f"{range_profile['fft_peak_distance_cm']:.1f} cm; "
                  "absolute range unverified without matched-path calibration")
        if not calibration_in_band:
            print("No RF subchirps match the calibration; board-delay offset is extrapolated")
        print(f"Saved {output / 'rx2_distance_profile.npz'}")
    print(f"Saved {interactive}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uri", default="ip:192.168.2.1")
    parser.add_argument("--output", type=Path, default=Path("artifacts/fmcw-rx2-1000-2000"))
    parser.add_argument("--rf-start", type=lambda value: int(float(value)), default=RF_START)
    parser.add_argument("--rf-stop", type=lambda value: int(float(value)), default=RF_STOP)
    parser.add_argument("--subchirp-span", type=lambda value: int(float(value)), default=SUBCHIRP_SPAN)
    parser.add_argument("--overlap", type=lambda value: int(float(value)), default=OVERLAP)
    parser.add_argument("--tx-atten", type=float, default=-30.0,
                        help="TX2 hardware gain in dB (default -30; must be <= -30)")
    parser.add_argument("--rx-gain", type=float, default=40.0)
    parser.add_argument("--amplitude", type=int, default=16000,
                        help="TX DAC peak count (default 16000)")
    parser.add_argument("--chirp-samples", type=int, default=65536)
    parser.add_argument("--capture-samples", type=int, default=65536)
    parser.add_argument("--check", action="store_true", help="validate waveform without the board")
    parser.add_argument("--reanalyze", action="store_true",
                        help="regenerate phase calibration and figures from --output's saved IQ")
    parser.add_argument("--resume", action="store_true",
                        help="reuse completed per-segment checkpoints after an interrupted board run")
    parser.add_argument("--calibration", type=Path,
                        help="TX2/RX2 path calibration JSON (default: use local artifacts calibration if present)")
    parser.add_argument("--no-calibration", action="store_true",
                        help="skip the local path calibration and distance chart")
    parser.add_argument("--distance-medium", choices=("coax", "air"), default="coax",
                        help="distance axis: one-way coax or round-trip air (default coax)")
    parser.add_argument("--air-refractive-index", type=float, default=1.0003,
                        help="radio refractive index for air distance (default 1.0003)")
    parser.add_argument("--max-range-m", type=float, default=100.0,
                        help="software low-pass stop range in metres (default 100; requires calibration)")
    args = parser.parse_args()
    try:
        segments = plan_segments(args.rf_start, args.rf_stop,
                                 args.subchirp_span, args.overlap)
    except ValueError as exc:
        parser.error(str(exc))
    if args.tx_atten > -30 or args.tx_atten < QUIET:
        parser.error("--tx-atten must be in [-89.75, -30] dB")
    if not 1 <= args.amplitude <= 16000:
        parser.error("--amplitude must be in [1, 16000]")
    if args.chirp_samples < 4096 or args.chirp_samples % 32:
        parser.error("--chirp-samples must be >=4096 and divisible by 32")
    if args.capture_samples < 8192 or args.capture_samples % 8:
        parser.error("--capture-samples must be >=8192 and divisible by 8")
    if args.capture_samples < 2 * (args.chirp_samples // DECIMATION):
        parser.error("--capture-samples must contain at least two complete chirps")
    if args.calibration and args.no_calibration:
        parser.error("--calibration and --no-calibration cannot be combined")
    if not np.isfinite(args.air_refractive_index) or args.air_refractive_index < 1:
        parser.error("--air-refractive-index must be finite and at least 1")
    if not np.isfinite(args.max_range_m) or args.max_range_m <= 0:
        parser.error("--max-range-m must be finite and positive")
    if args.check:
        print(f"{len(segments)} TX2 settings cover {args.rf_start / 1e6:g}–"
              f"{args.rf_stop / 1e6:g} MHz with {args.overlap / 1e6:g} MHz overlap")
        for low, high in (segments if len(segments) <= 6 else
                          segments[:3] + segments[-3:]):
            iq = chirp(FS, low, high, (low + high) // 2,
                       args.chirp_samples, args.amplitude)
            print(f"{low / 1e6:.1f}-{high / 1e6:.1f} MHz: {len(iq)} samples, "
                  f"peak {np.abs(iq).max():.0f} DAC counts")
        return 0
    if importlib.util.find_spec("plotly") is None:
        parser.error("interactive charts need Plotly: "
                     ".venv/bin/python -m pip install -r tools/fmcw-requirements.txt")
    calibration_path = (None if args.no_calibration else
                        args.calibration or (DEFAULT_CALIBRATION if DEFAULT_CALIBRATION.exists() else None))
    try:
        calibration = load_calibration(calibration_path) if calibration_path else None
    except (OSError, ValueError, TypeError) as exc:
        parser.error(str(exc))
    if calibration is None:
        print("No TX2/RX2 path calibration found; interactive distance chart skipped")
    if args.reanalyze:
        previous = json.loads((args.output / "metadata.json").read_text())
        with np.load(args.output / "rx2_beat.npz") as raw:
            results = [{**segment, "samples": raw[f"segment_{i + 1}"].copy()}
                       for i, segment in enumerate(previous["segments"])]
        return save_results(results, args.output, previous["captured_utc"],
                            calibration, calibration_path,
                            args.distance_medium, args.air_refractive_index,
                            args.max_range_m)

    args.output.mkdir(parents=True, exist_ok=True)
    checkpoint_dir = args.output / "segments"
    checkpoint_dir.mkdir(exist_ok=True)
    cached = {}
    if args.resume:
        for index, (low, high) in enumerate(segments, 1):
            path = checkpoint_dir / f"segment_{index:03d}.npz"
            if not path.exists():
                continue
            with np.load(path) as saved:
                if (int(saved["rf_low_hz"]) != low or int(saved["rf_high_hz"]) != high or
                        len(saved["samples"]) != args.capture_samples or
                        int(saved["chirp_samples"]) != args.chirp_samples):
                    parser.error(f"checkpoint settings differ: {path}")
                cached[index] = {key: saved[key].item() if saved[key].ndim == 0 else saved[key].copy()
                                 for key in saved.files}
    if len(cached) == len(segments):
        print(f"Reusing all {len(cached)} segment checkpoints; no RF transmission", flush=True)
        first_checkpoint = checkpoint_dir / "segment_001.npz"
        captured_at = datetime.fromtimestamp(first_checkpoint.stat().st_mtime,
                                             timezone.utc).isoformat()
        return save_results([cached[i] for i in range(1, len(segments) + 1)],
                            args.output, captured_at, calibration, calibration_path,
                            args.distance_medium, args.air_refractive_index,
                            args.max_range_m)

    board = Board(args.uri, timeout=30.0)
    board.save_state()
    rx2_old_mode = board.rd(PHY, "voltage1", "gain_control_mode")
    rx2_old_gain = board.rd(PHY, "voltage1", "hardwaregain")
    tx_old_bw = board.rd(PHY, "voltage0", "rf_bandwidth", True)
    results = []
    try:
        if not board.mute_tx():
            raise RuntimeError("cannot verify TX mute before radio configuration")
        board.wr(PHY, "voltage0", "sampling_frequency", FS)
        board.wr(PHY, "voltage0", "rf_bandwidth", RX_RF_BW)
        board.wr(PHY, "voltage0", "rf_bandwidth", TX_RF_BW, True)
        board.set_rx_gain(args.rx_gain, 1)
        board.c.write_device(board.dev[RX][0], "in_voltage_sampling_frequency", str(DELIVERED))
        delivered = float(board.c.read_device(board.dev[RX][0], "in_voltage_sampling_frequency"))
        if abs(delivered - DELIVERED) > 1:
            raise RuntimeError(f"FPGA /8 FIR did not engage: RX rate={delivered}")
        print(f"AD9361 {FS / 1e6:g} MSPS, RX2 FIR output {delivered / 1e6:g} MSPS", flush=True)
        for index, (low, high) in enumerate(segments, 1):
            if index in cached:
                print(f"Segment {index}/{len(segments)} reused from checkpoint", flush=True)
                results.append(cached[index])
                continue
            print(f"Segment {index}/{len(segments)}", flush=True)
            result = acquire_segment(board, low, high, args)
            results.append(result)
            checkpoint = checkpoint_dir / f"segment_{index:03d}.npz"
            temporary = checkpoint.with_name(checkpoint.stem + ".tmp.npz")
            np.savez_compressed(temporary, **result)
            temporary.replace(checkpoint)
    finally:
        # Even if configuration or capture fails, do not leave a cyclic TX DMA live.
        board.tx_stop()
        board.restore_state()
        try:
            if rx2_old_mode == "manual":
                board.wr(PHY, "voltage1", "hardwaregain", rx2_old_gain)
            board.wr(PHY, "voltage1", "gain_control_mode", rx2_old_mode)
            board.wr(PHY, "voltage0", "rf_bandwidth", tx_old_bw, True)
        finally:
            board.c.close()

    captured_at = None
    if cached:
        first_saved = min((checkpoint_dir / f"segment_{i:03d}.npz").stat().st_mtime
                          for i in cached)
        captured_at = datetime.fromtimestamp(first_saved, timezone.utc).isoformat()
    return save_results(results, args.output, captured_at, calibration, calibration_path,
                        args.distance_medium, args.air_refractive_index,
                        args.max_range_m)


if __name__ == "__main__":
    raise SystemExit(main())
