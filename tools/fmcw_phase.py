"""Overlap-based phase referencing for segmented FMCW beat captures.

Each segment is an independently tuned measurement. The phase of its TX/RX
synthesizers is arbitrary after an LO retune. In the shared RF band, however,
the same stationary loopback has the same phase-versus-frequency response.
Fit the complex cross-product there to transfer one segment's phase reference
to the next, including a small differential delay (linear phase slope).
This is the same calibration idea as phase/delay transfer between spectral
windows in radio interferometry; it does not create an absolute RF phase.
"""

from __future__ import annotations

import numpy as np


def response_profile(segment: dict, decimation: int = 8) -> dict:
    """Fold repeated chirps, then locate the tapered wrap by its amplitude dip."""
    period = int(segment["chirp_samples"]) // decimation
    samples = np.asarray(segment["samples"], dtype=np.complex128)
    cycles = len(samples) // period
    if period < 128 or cycles < 2 or segment["chirp_samples"] % decimation:
        raise ValueError("phase recovery needs at least two complete chirps")
    folded = samples[:cycles * period].reshape(cycles, period).mean(axis=0)
    # A circular moving average rejects quantization noise while retaining the
    # deep taper dip. The dip marks the start of the known frequency ramp.
    half = max(4, period // 256)
    magnitude = np.abs(folded)
    smooth = np.convolve(np.r_[magnitude[-half:], magnitude, magnitude[:half]],
                         np.ones(2 * half + 1) / (2 * half + 1), mode="valid")
    seam = int(np.argmin(smooth))
    response = np.roll(folded, -seam)
    low, high = float(segment["rf_low_hz"]), float(segment["rf_high_hz"])
    frequency = low + (high - low) * np.arange(period) / period
    return {"frequency_hz": frequency, "response": response,
            "seam_sample": seam, "coherent_chirps": cycles,
            "rf_low_hz": low, "rf_high_hz": high}


def _overlap(reference: dict, target: dict, guard: float = 0.04) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Complex responses on the reference's frequency grid, away from wraps."""
    f = reference["frequency_hz"]
    a_low, a_high = reference["rf_low_hz"], reference["rf_high_hz"]
    b_low, b_high = target["rf_low_hz"], target["rf_high_hz"]
    usable_low = max(a_low + guard * (a_high - a_low), b_low + guard * (b_high - b_low))
    usable_high = min(a_high - guard * (a_high - a_low), b_high - guard * (b_high - b_low))
    if usable_high - usable_low < 1e6:
        raise ValueError("less than 1 MHz of usable RF overlap for phase reference")
    selected = (f >= usable_low) & (f <= usable_high)
    common = f[selected]
    a = reference.get("corrected", reference["response"])[selected]
    bf = target["frequency_hz"]
    bx = target.get("corrected", target["response"])
    b = np.interp(common, bf, bx.real) + 1j * np.interp(common, bf, bx.imag)
    # Reject isolated low-SNR or filter-edge samples before phase unwrapping.
    strong = ((np.abs(a) >= 0.2 * np.median(np.abs(a))) &
              (np.abs(b) >= 0.2 * np.median(np.abs(b))))
    if np.count_nonzero(strong) < 64:
        raise ValueError("overlap has fewer than 64 useful phase samples")
    return common[strong], a[strong], b[strong]


def fit_overlap(reference: dict, target: dict) -> dict:
    """Estimate phase and differential delay to rotate target into reference."""
    frequency, a, b = _overlap(reference, target)
    cross = a * np.conj(b)
    weight = np.abs(cross)
    center = float(np.average(frequency, weights=weight))
    mhz = (frequency - center) / 1e6
    phase = np.unwrap(np.angle(cross))
    # Weighted least squares is the phase/delay calibration. A second pass
    # suppresses narrow spurs without letting low-SNR bins decide the phase.
    good = np.ones(len(phase), dtype=bool)
    for _ in range(2):
        slope, intercept = np.polyfit(mhz[good], phase[good], 1,
                                      w=np.sqrt(weight[good] / weight[good].max()))
        residual = np.angle(np.exp(1j * (phase - (slope * mhz + intercept))))
        scale = max(0.02, 1.4826 * np.median(np.abs(residual - np.median(residual))))
        good = np.abs(residual) <= max(0.15, 4 * scale)
    model = slope * mhz + intercept
    coherent_before = float(np.abs(cross.sum()) / weight.sum())
    coherent_after = float(np.abs(np.sum(cross * np.exp(-1j * model))) / weight.sum())
    raw_rms_deg = float(np.sqrt(np.average(np.angle(cross) ** 2, weights=weight)) * 180 / np.pi)
    rms_deg = float(np.sqrt(np.average(
        np.angle(np.exp(1j * (phase - model))) ** 2, weights=weight)) * 180 / np.pi)
    if coherent_after < 0.95 or rms_deg > 20:
        raise ValueError(f"overlap phase is not coherent: {coherent_after:.3f}, {rms_deg:.1f} deg RMS")
    correction = intercept + slope * (target["frequency_hz"] - center) / 1e6
    target["corrected"] = target["response"] * np.exp(1j * correction)
    return {"overlap_low_hz": float(frequency.min()),
            "overlap_high_hz": float(frequency.max()),
            "phase_reference_hz": center,
            "phase_correction_rad": float(np.angle(np.exp(1j * intercept))),
            "phase_slope_rad_per_mhz": float(slope),
            "differential_delay_ns": float(slope / (2 * np.pi) * 1e3),
            "coherence_before": coherent_before,
            "coherence_after": coherent_after,
            "mismatch_before_rms_deg": raw_rms_deg,
            "residual_rms_deg": rms_deg,
            "points": int(len(frequency))}


def recover_phase(segments: list[dict]) -> tuple[list[dict], list[dict], dict, dict]:
    """Reference all segments to the first, and stitch their complex response."""
    profiles = [response_profile(segment) for segment in segments]
    profiles[0]["corrected"] = profiles[0]["response"].copy()
    calibrations = []
    for index in range(1, len(profiles)):
        record = fit_overlap(profiles[index - 1], profiles[index])
        record.update({"reference_segment": index, "target_segment": index + 1})
        calibrations.append(record)

    triples = []
    for index in range(len(profiles) - 2):
        try:
            f, a, b = _overlap(profiles[index], profiles[index + 2])
            cross = a * np.conj(b)
            weight = np.abs(cross)
            triples.append({"first_segment": index + 1,
                            "third_segment": index + 3,
                            "rf_low_hz": float(f.min()), "rf_high_hz": float(f.max()),
                            "residual_phase_deg": float(np.angle(cross.sum()) * 180 / np.pi),
                            "coherence": float(np.abs(cross.sum()) / weight.sum())})
        except ValueError:
            pass
    closure = {}
    if triples:
        phases = np.array([t["residual_phase_deg"] for t in triples])
        closure = {"count": len(triples),
                   "rms_phase_deg": float(np.sqrt(np.mean(phases ** 2))),
                   "max_abs_phase_deg": float(np.max(np.abs(phases))),
                   "min_coherence": float(min(t["coherence"] for t in triples)),
                   "triples": triples}
        if len(triples) == 1:
            closure.update(triples[0])

    low = min(p["rf_low_hz"] for p in profiles)
    high = max(p["rf_high_hz"] for p in profiles)
    grid = np.arange(low, high + 1, 4000.0)
    accumulator = np.zeros(len(grid), dtype=np.complex128)
    total_weight = np.zeros(len(grid), dtype=np.float64)
    for p in profiles:
        fractional = (grid - p["rf_low_hz"]) / (p["rf_high_hz"] - p["rf_low_hz"])
        inside = (fractional >= 0.015) & (fractional <= 0.985)
        f = grid[inside]
        r = p["corrected"]
        value = np.interp(f, p["frequency_hz"], r.real) + 1j * np.interp(f, p["frequency_hz"], r.imag)
        weight = np.sin(np.pi * fractional[inside]) ** 2
        accumulator[inside] += weight * value
        total_weight[inside] += weight
    valid = total_weight > 0
    stitched = np.zeros(len(grid), dtype=np.complex64)
    stitched[valid] = (accumulator[valid] / total_weight[valid]).astype(np.complex64)
    return profiles, calibrations, closure, {"frequency_hz": grid, "response": stitched,
                                              "valid": valid}


def plot_phase(profiles: list[dict], calibrations: list[dict], closure: dict,
               stitched: dict, output) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    if len(profiles) > 10:
        fig, axes = plt.subplots(3, 1, figsize=(13, 10), layout="constrained")
        valid = stitched["valid"]
        f = stitched["frequency_hz"][valid] / 1e6
        phase = np.unwrap(np.angle(stitched["response"][valid])) / (2 * np.pi)
        axes[0].plot(f[::20], phase[::20], lw=0.9)
        axes[0].set(title="Phase-referenced, concatenated RX2 beat",
                    xlabel="Transmitted RF frequency (MHz)", ylabel="Unwrapped phase (cycles)")
        center = np.array([c["phase_reference_hz"] for c in calibrations]) / 1e6
        before = [c["mismatch_before_rms_deg"] for c in calibrations]
        after = [c["residual_rms_deg"] for c in calibrations]
        axes[1].semilogy(center, before, ".-", label="Before")
        axes[1].semilogy(center, after, ".-", label="After")
        axes[1].set(title="Adjacent 20 MHz overlap mismatch",
                    xlabel="Overlap center (MHz)", ylabel="RMS phase mismatch (degrees, log scale)")
        axes[1].set_ylim(1, 200)
        axes[1].legend()
        if closure:
            triples = closure["triples"]
            third_center = [(t["rf_low_hz"] + t["rf_high_hz"]) / 2e6 for t in triples]
            axes[2].plot(third_center, [t["residual_phase_deg"] for t in triples], ".-")
            axes[2].axhline(0, color="black", lw=0.6)
            axes[2].set(title=f"Three-way closure: {closure['rms_phase_deg']:.2f}° RMS, "
                              f"{closure['max_abs_phase_deg']:.2f}° maximum",
                        xlabel="Three-way overlap center (MHz)",
                        ylabel="Closure phase (degrees)")
        for axis in axes:
            axis.grid(alpha=0.25)
        fig.savefig(output / "rx2_phase_recovery.png", dpi=160)
        plt.close(fig)
        return

    fig, axes = plt.subplots(2, 1, figsize=(13, 8), layout="constrained")
    previous_f = previous_phase = None
    colors = plt.rcParams["axes.prop_cycle"].by_key()["color"]
    for index, p in enumerate(profiles):
        f = p["frequency_hz"]
        phase = np.unwrap(np.angle(p["corrected"]))
        if previous_f is not None:
            common = (f >= previous_f[0]) & (f <= previous_f[-1])
            delta = np.median(np.interp(f[common], previous_f, previous_phase) - phase[common])
            phase += 2 * np.pi * round(delta / (2 * np.pi))
        axes[0].plot(f / 1e6, phase / (2 * np.pi), color=colors[index], lw=1,
                     label=f"Segment {index + 1} phase referenced")
        previous_f, previous_phase = f, phase
    axes[0].set(title="Recovered RX2 beat phase across the segmented RF sweep",
                xlabel="Transmitted RF frequency (MHz)", ylabel="Unwrapped phase (cycles)")
    axes[0].legend()
    axes[0].grid(alpha=0.25)

    phase_extent = 20.0
    for index, cal in enumerate(calibrations, 1):
        reference = profiles[index - 1]
        target = profiles[index]
        f, a, b = _overlap(reference, {**target, "corrected": target["response"]})
        before = np.angle(a * np.conj(b)) * 180 / np.pi
        _, a, after_b = _overlap(reference, target)
        after = np.angle(a * np.conj(after_b)) * 180 / np.pi
        phase_extent = max(phase_extent, float(np.max(np.abs(before))) + 5)
        color = colors[index - 1]
        axes[1].plot(f / 1e6, before, color=color, alpha=0.3, lw=0.7,
                     label=f"{index}→{index + 1} before")
        axes[1].plot(f / 1e6, after, color=color, lw=1,
                     label=f"{index}→{index + 1} after ({cal['residual_rms_deg']:.2f}° RMS)")
    axes[1].set(title="Shared-band phase mismatch before and after calibration",
                xlabel="Transmitted RF frequency (MHz)", ylabel="Phase mismatch (degrees)",
                ylim=(-min(190, phase_extent), min(190, phase_extent)))
    axes[1].legend(ncol=2)
    axes[1].grid(alpha=0.25)
    if closure:
        fig.suptitle(f"Three-way closure across {closure['count']} triples: "
                     f"{closure['rms_phase_deg']:.2f}° RMS, "
                     f"{closure['max_abs_phase_deg']:.2f}° maximum; "
                     f"minimum coherence {closure['min_coherence']:.4f}")
    fig.savefig(output / "rx2_phase_recovery.png", dpi=160)
    plt.close(fig)
