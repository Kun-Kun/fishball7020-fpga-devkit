#!/usr/bin/env python3
"""Calibrate TX2-to-RX2 FMCW delay with two known coax lengths.

Compare raw beat phase slopes in identical RF subchirps. This avoids FFT-bin
rounding and does not depend on the overlap pattern used to stitch each run.
The resulting fixed path delay includes the radio and FPGA signal chains.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from fmcw_phase import response_profile


LIGHT_SPEED_M_PER_S = 299_792_458


def profiles_from_run(run: Path) -> tuple[dict, dict]:
    metadata = json.loads((run / "metadata.json").read_text())
    profiles = {}
    with np.load(run / "rx2_beat.npz") as raw:
        for index, segment in enumerate(metadata["segments"], 1):
            key = (int(segment["rf_low_hz"]), int(segment["rf_high_hz"]),
                   int(segment["chirp_samples"]), int(segment["rx2_rate_hz"]))
            if key in profiles:
                raise ValueError(f"duplicate subchirp in {run}: {key}")
            profiles[key] = response_profile({**segment, "samples": raw[f"segment_{index}"]})
    return metadata, profiles


def phase_delay_ns(frequency_hz: np.ndarray, response: np.ndarray,
                   strong: np.ndarray) -> tuple[float, float]:
    """Return positive group delay and circular phase-fit residual in degrees."""
    low, high = frequency_hz[0], frequency_hz[-1]
    usable = ((frequency_hz >= low + 2e6) & (frequency_hz <= high - 2e6) & strong)
    if usable.sum() < 128 or np.ptp(frequency_hz[usable]) < 10e6:
        raise ValueError("subchirp has insufficient strong, usable samples")
    center = np.mean(frequency_hz[usable])
    phase = np.unwrap(np.angle(response))
    weights = np.sqrt(np.abs(response[usable]))
    slope, intercept = np.polyfit(frequency_hz[usable] - center, phase[usable], 1,
                                  w=weights)
    residual = np.angle(np.exp(1j * (phase[usable] -
                                   (slope * (frequency_hz[usable] - center) + intercept))))
    rms_deg = float(np.sqrt(np.average(residual ** 2, weights=weights ** 2)) * 180 / np.pi)
    return float(-slope / (2 * np.pi) * 1e9), rms_deg


def fit_calibration(short_run: Path, short_length_m: float,
                    long_run: Path, long_length_m: float) -> dict:
    if not (0 <= short_length_m < long_length_m):
        raise ValueError("known cable lengths must be nonnegative and increasing")
    short_meta, short = profiles_from_run(short_run)
    long_meta, long = profiles_from_run(long_run)
    common = sorted(set(short) & set(long))
    if not common:
        raise ValueError("runs have no identical RF subchirps and sample rates")
    matches = []
    for key in common:
        a, b = short[key], long[key]
        frequency = a["frequency_hz"]
        if not np.array_equal(frequency, b["frequency_hz"]):
            raise ValueError(f"RF grids differ for {key}")
        short_iq, long_iq = a["response"], b["response"]
        strong = ((np.abs(short_iq) >= 0.2 * np.median(np.abs(short_iq))) &
                  (np.abs(long_iq) >= 0.2 * np.median(np.abs(long_iq))))
        short_delay, short_rms = phase_delay_ns(frequency, short_iq, strong)
        added_delay, added_rms = phase_delay_ns(frequency, long_iq * np.conj(short_iq),
                                               strong)
        matches.append({"rf_low_hz": key[0], "rf_high_hz": key[1],
                        "chirp_samples": key[2], "rx2_rate_hz": key[3],
                        "short_total_delay_ns": short_delay,
                        "added_cable_delay_ns": added_delay,
                        "short_phase_residual_rms_deg": short_rms,
                        "difference_phase_residual_rms_deg": added_rms})
    added = np.array([item["added_cable_delay_ns"] for item in matches])
    if np.any(added <= 0):
        raise ValueError("longer cable did not increase delay in every matched subchirp")
    delay_per_meter = float(np.median(added) / (long_length_m - short_length_m))
    velocity_factor = float(1 / (LIGHT_SPEED_M_PER_S * delay_per_meter * 1e-9))
    if not 0 < velocity_factor <= 1:
        raise ValueError(f"implausible coax velocity factor {velocity_factor:.3f}")
    board_delays = np.array([item["short_total_delay_ns"] -
                             short_length_m * delay_per_meter for item in matches])
    result = {
        "method": "phase slope of matched raw TX2/RX2 subchirps; median cable difference",
        "short_run": str(short_run), "short_captured_utc": short_meta["captured_utc"],
        "short_length_m": short_length_m,
        "long_run": str(long_run), "long_captured_utc": long_meta["captured_utc"],
        "long_length_m": long_length_m,
        "matched_subchirps": len(matches),
        "added_cable_delay_ns_median": float(np.median(added)),
        "added_cable_delay_ns_min": float(np.min(added)),
        "added_cable_delay_ns_max": float(np.max(added)),
        "coax_delay_ns_per_meter": delay_per_meter,
        "coax_velocity_factor": velocity_factor,
        "fixed_path_delay_ns_median": float(np.median(board_delays)),
        "fixed_path_delay_ns_min": float(np.min(board_delays)),
        "fixed_path_delay_ns_max": float(np.max(board_delays)),
        "matches": matches,
    }
    return result


def measure_profiles(profiles: dict, calibration: dict) -> dict:
    """Estimate cable length from already computed raw subchirp profiles."""
    lengths = []
    for reference in calibration["matches"]:
        key = (reference["rf_low_hz"], reference["rf_high_hz"],
               reference["chirp_samples"], reference["rx2_rate_hz"])
        if key not in profiles:
            continue
        profile = profiles[key]
        response = profile["response"]
        strong = np.abs(response) >= 0.2 * np.median(np.abs(response))
        total_delay, phase_rms = phase_delay_ns(profile["frequency_hz"], response, strong)
        cable_length = (calibration["short_length_m"] +
                        (total_delay - reference["short_total_delay_ns"]) *
                        (calibration["long_length_m"] - calibration["short_length_m"]) /
                        reference["added_cable_delay_ns"])
        lengths.append({"rf_low_hz": key[0], "rf_high_hz": key[1],
                        "estimated_length_m": cable_length,
                        "total_delay_ns": total_delay,
                        "phase_residual_rms_deg": phase_rms})
    if not lengths:
        raise ValueError("measurement has no RF subchirps matching the calibration")
    return {"matched_subchirps": len(lengths),
            "estimated_length_m_median": float(np.median(
                [item["estimated_length_m"] for item in lengths])),
            "subchirps": lengths}


def measure_length(run: Path, calibration: dict) -> dict:
    """Compare a saved capture with the calibrated short-cable phase slopes."""
    metadata, profiles = profiles_from_run(run)
    return {"run": str(run), "captured_utc": metadata["captured_utc"],
            **measure_profiles(profiles, calibration)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--short-run", type=Path, required=True)
    parser.add_argument("--short-length-m", type=float, required=True)
    parser.add_argument("--long-run", type=Path, required=True)
    parser.add_argument("--long-length-m", type=float, required=True)
    parser.add_argument("--measure-run", type=Path,
                        help="also estimate the cable length of another saved capture")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = fit_calibration(args.short_run, args.short_length_m,
                                 args.long_run, args.long_length_m)
        if args.measure_run:
            result["measurement"] = measure_length(args.measure_run, result)
    except (OSError, KeyError, ValueError) as exc:
        parser.error(str(exc))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Matched subchirps: {result['matched_subchirps']}")
    print(f"Added cable delay: {result['added_cable_delay_ns_median']:.3f} ns")
    print(f"Coax delay: {result['coax_delay_ns_per_meter']:.3f} ns/m; "
          f"velocity factor: {result['coax_velocity_factor']:.3f}")
    print(f"Fixed TX2/RX2 path delay: {result['fixed_path_delay_ns_median']:.3f} ns")
    if "measurement" in result:
        print(f"Measured cable length: "
              f"{result['measurement']['estimated_length_m_median']:.3f} m")
    print(f"Saved {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
