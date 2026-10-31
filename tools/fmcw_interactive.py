"""Standalone interactive plots for a phase-referenced TX2/RX2 FMCW capture."""

from __future__ import annotations

from html import escape
from pathlib import Path

import numpy as np


def beat_overview_indices(sample_count: int, max_points: int = 50_000) -> np.ndarray:
    """Cover the full beat with a bounded number of displayed samples."""
    if sample_count < 1 or max_points < 2:
        raise ValueError("beat and display point limit must be nonempty")
    stride = max(1, (sample_count + max_points - 1) // max_points)
    indices = np.arange(0, sample_count, stride)
    if indices[-1] != sample_count - 1:
        indices = np.append(indices, sample_count - 1)
    return indices


def beat_spectrum(beat: np.ndarray, sample_rate_hz: float,
                  fft_size: int | None = None) -> tuple[np.ndarray, np.ndarray]:
    centered = beat - beat.mean()
    fft_size = fft_size or len(beat)
    spectrum = np.fft.fftshift(np.fft.fft(centered * np.hanning(len(beat)), n=fft_size))
    frequency_hz = np.fft.fftshift(np.fft.fftfreq(fft_size, 1 / sample_rate_hz))
    return frequency_hz, np.abs(spectrum)


def low_pass_range(beat: np.ndarray, sample_rate_hz: float,
                   chirp_slope_hz_per_s: float, fixed_path_delay_ns: float,
                   propagation_delay_ns_per_meter: float,
                   max_range_m: float = 100.0) -> tuple[np.ndarray, dict]:
    """Remove virtual-beat frequencies corresponding to ranges beyond max_range_m.

    A raised-cosine transition over the final 10% of the range avoids the
    time-domain ringing of a sharp FFT cutoff. Reflecting the sweep ends keeps
    the FFT from joining the first and last samples as though they were
    adjacent in time. Both I and Q receive the same zero-phase filter.
    """
    if (len(beat) < 2 or sample_rate_hz <= 0 or chirp_slope_hz_per_s <= 0 or
            propagation_delay_ns_per_meter <= 0 or max_range_m <= 0 or
            not np.all(np.isfinite([sample_rate_hz, chirp_slope_hz_per_s,
                                    fixed_path_delay_ns, propagation_delay_ns_per_meter,
                                    max_range_m]))):
        raise ValueError("beat, rates, path delay and maximum range must be valid")
    pass_range_m = 0.9 * max_range_m
    pass_hz = chirp_slope_hz_per_s * (
        fixed_path_delay_ns + pass_range_m * propagation_delay_ns_per_meter) * 1e-9
    stop_hz = chirp_slope_hz_per_s * (
        fixed_path_delay_ns + max_range_m * propagation_delay_ns_per_meter) * 1e-9
    if pass_hz < 0 or stop_hz <= pass_hz or stop_hz >= sample_rate_hz / 2:
        raise ValueError("range cutoff lies outside the virtual beat Nyquist band")
    padding = min(len(beat) - 1, max(256, int(np.ceil(20 * sample_rate_hz /
                                                  pass_hz))))
    extended = np.pad(beat, (padding, padding), mode="reflect")
    frequency_hz = np.abs(np.fft.fftfreq(len(extended), 1 / sample_rate_hz))
    gain = np.ones(len(extended))
    transition = (frequency_hz > pass_hz) & (frequency_hz < stop_hz)
    gain[transition] = 0.5 * (1 + np.cos(np.pi *
                                        (frequency_hz[transition] - pass_hz) /
                                        (stop_hz - pass_hz)))
    gain[frequency_hz >= stop_hz] = 0
    filtered = np.fft.ifft(np.fft.fft(extended) * gain)[padding:-padding]
    return filtered, {"method": "zero-phase FFT raised-cosine low-pass",
                      "max_range_m": max_range_m,
                      "pass_range_m": pass_range_m,
                      "pass_frequency_hz": float(pass_hz),
                      "stop_frequency_hz": float(stop_hz)}


def distance_profile(beat: np.ndarray, sample_rate_hz: float, chirp_slope_hz_per_s: float,
                     rf_bandwidth_hz: float, fixed_path_delay_ns: float,
                     propagation_delay_ns_per_meter: float,
                     max_distance_m: float = 1000.0) -> dict:
    """Map the virtual beat spectrum to distance using the path delay per metre."""
    if (sample_rate_hz <= 0 or chirp_slope_hz_per_s <= 0 or rf_bandwidth_hz <= 0 or
            propagation_delay_ns_per_meter <= 0 or max_distance_m <= 0):
        raise ValueError("sample rate, chirp slope, RF bandwidth and path delay must be positive")
    fft_size = 1 << (8 * len(beat) - 1).bit_length()
    beat_frequency_hz, magnitude = beat_spectrum(beat, sample_rate_hz, fft_size)
    distance_cm = ((-beat_frequency_hz / chirp_slope_hz_per_s * 1e9 -
                    fixed_path_delay_ns) / propagation_delay_ns_per_meter * 100)
    usable = ((beat_frequency_hz < 0) & (distance_cm >= 0) &
              (distance_cm <= max_distance_m * 100))
    if not np.any(usable):
        raise ValueError("no positive calibrated distance falls within the beat spectrum")
    # FFT frequency rises from left to right, whereas calibrated distance falls.
    x = distance_cm[usable][::-1]
    amplitude = magnitude[usable][::-1]
    relative_db = 20 * np.log10(np.maximum(amplitude, 1e-12) / amplitude.max())
    strongest = int(np.argmax(amplitude))
    return {"distance_cm": x, "relative_db": relative_db,
            "fft_peak_distance_cm": float(x[strongest]),
            "display_step_cm": float(100 * sample_rate_hz / (fft_size * chirp_slope_hz_per_s *
                                                             propagation_delay_ns_per_meter * 1e-9)),
            "distance_resolution_cm": float(100 / (rf_bandwidth_hz *
                                                   propagation_delay_ns_per_meter * 1e-9))}


def save_interactive(results: list[dict], stitched: dict, calibrations: list[dict],
                     closure: dict, beat: np.ndarray, frequency_hz: np.ndarray,
                     time_s: np.ndarray, virtual_rate_hz: float, output: Path,
                     captured_utc: str, distance: dict | None = None,
                     measurement: dict | None = None, calibration_source: str | None = None,
                     distance_medium: str = "coax", air_refractive_index: float = 1.0003,
                     calibration_in_band: bool = True,
                     filter_info: dict | None = None) -> Path:
    """Write one self-contained HTML dashboard with Plotly zoom, pan and hover."""
    try:
        import plotly.graph_objects as go
        import plotly.io as pio
        from plotly.subplots import make_subplots
    except ImportError as exc:
        raise RuntimeError("interactive charts need Plotly: "
                           ".venv/bin/python -m pip install -r tools/fmcw-requirements.txt") from exc

    figures = []
    if distance is not None:
        median_cm = measurement["estimated_length_m_median"] * 100 if measurement else None
        range_name = "Air target range" if distance_medium == "air" else "One-way cable length"
        if median_cm is not None:
            fig = make_subplots(rows=2, cols=1, row_heights=[0.65, 0.35],
                                vertical_spacing=0.16,
                                subplot_titles=("Calibrated range profile (virtual sweep FFT)",
                                                "Cable length from matched raw subchirps"))
        else:
            fig = make_subplots(rows=1, cols=1,
                                subplot_titles=("Estimated range profile (virtual sweep FFT)",))
        fig.add_trace(go.Scatter(x=distance["distance_cm"], y=distance["relative_db"],
                                 mode="lines", name="Range response", line_color="#2266bb",
                                 hovertemplate="%{x:.1f} cm<br>%{y:.1f} dB relative<extra></extra>"),
                      row=1, col=1)
        if median_cm is not None:
            fig.add_vline(x=median_cm, line_color="#d04b32", line_dash="dash", row=1, col=1)
            fig.add_hline(y=median_cm, line_color="#d04b32", line_dash="dash", row=2, col=1)
            subchirps = measurement["subchirps"]
            center_mhz = [(s["rf_low_hz"] + s["rf_high_hz"]) / 2e6 for s in subchirps]
            residual = [s["phase_residual_rms_deg"] for s in subchirps]
            fig.add_trace(go.Scatter(x=center_mhz,
                                     y=[s["estimated_length_m"] * 100 for s in subchirps],
                                     mode="markers+lines", name="Matched windows",
                                     marker=dict(size=9, color="#d04b32"),
                                     customdata=np.asarray(residual)[:, None],
                                     hovertemplate=("RF %{x:.1f} MHz<br>%{y:.1f} cm"
                                                    "<br>phase fit %{customdata[0]:.2f}° RMS"
                                                    "<extra></extra>")), row=2, col=1)
        fig.update_xaxes(title_text=f"{range_name} (cm)",
                         range=[0, max(1500, 2 * median_cm)] if median_cm is not None else None,
                         row=1, col=1)
        fig.update_yaxes(title_text="Relative amplitude (dB)", range=[-90, 5], row=1, col=1)
        if median_cm is not None:
            fig.update_xaxes(title_text="Subchirp RF center (MHz)", row=2, col=1)
            fig.update_yaxes(title_text="Estimated cable length (cm)", row=2, col=1)
        fig.update_layout(title=(f"TX2→RX2 calibrated distance: {median_cm:.1f} cm median"
                                 if median_cm is not None else f"TX2→RX2 estimated {range_name.lower()}"),
                          height=760 if median_cm is not None else 500, hovermode="closest")
        figures.append(("distance", "Distance estimate", fig))

    full = np.arange(len(beat))
    fig = go.Figure()
    for values, label, color in ((beat.real, "I", "#2266bb"),
                                 (beat.imag, "Q", "#d04b32")):
        fig.add_trace(go.Scattergl(
            x=time_s[full] * 1e3, y=values[full], mode="lines", name=label,
            line=dict(color=color, width=1),
            hovertemplate="%{x:.4f} ms<br>%{y:.1f} RX2 counts<extra>" + label + "</extra>"))
    fig.update_layout(title="Full phase-referenced virtual beat I/Q" +
                      (f" ({filter_info['max_range_m']:g} m low-pass)"
                       if filter_info is not None else ""),
                      xaxis_title="Virtual sweep time (ms)",
                      yaxis_title="RX2 DMA counts", height=530,
                      hovermode="x unified")
    figures.append(("full-beat", "Full beat I/Q", fig))

    beat_frequency_hz, beat_magnitude = beat_spectrum(beat, virtual_rate_hz)
    beat_band = np.abs(beat_frequency_hz) <= 100_000
    beat_db = 20 * np.log10(np.maximum(beat_magnitude[beat_band], 1e-12) /
                             (len(beat) / 2))
    fig = make_subplots(rows=3, cols=1, vertical_spacing=0.11,
                        subplot_titles=("First 0.3 ms of phase-referenced beat",
                                        "Beat magnitude across virtual sweep",
                                        "Full beat spectrum"))
    short = time_s <= time_s[0] + 0.3e-3
    for values, label, color in ((beat.real, "I", "#2266bb"),
                                 (beat.imag, "Q", "#d04b32")):
        fig.add_trace(go.Scatter(x=time_s[short] * 1e3, y=values[short], mode="lines",
                                 name=label, line=dict(color=color, width=1)), row=1, col=1)
    stride = max(1, len(beat) // 12000)
    fig.add_trace(go.Scatter(x=time_s[::stride] * 1e3, y=np.abs(beat[::stride]),
                             mode="lines", name="Magnitude", line_color="#23856b"),
                  row=2, col=1)
    fig.add_trace(go.Scatter(x=beat_frequency_hz[beat_band] / 1e3, y=beat_db,
                             mode="lines", name="Spectrum", line_color="#6c4ab0"),
                  row=3, col=1)
    fig.update_xaxes(title_text="Virtual time (ms)", row=1, col=1)
    fig.update_yaxes(title_text="RX2 counts", row=1, col=1)
    fig.update_xaxes(title_text="Virtual time (ms)", row=2, col=1)
    fig.update_yaxes(title_text="RX2 counts", row=2, col=1)
    fig.update_xaxes(title_text="Beat frequency (kHz)", row=3, col=1)
    fig.update_yaxes(title_text="dB re DMA count", row=3, col=1)
    fig.update_layout(title="Concatenated complex beat", height=970, hovermode="x unified")
    figures.append(("beat", "Beat and spectrum", fig))

    valid = stitched["valid"]
    rf = stitched["frequency_hz"][valid]
    phase_cycles = np.unwrap(np.angle(stitched["response"][valid])) / (2 * np.pi)
    phase_stride = max(1, len(rf) // 15000)
    fig = make_subplots(rows=3, cols=1, vertical_spacing=0.12,
                        subplot_titles=("Phase-referenced response",
                                        "Adjacent overlap mismatch",
                                        "Three-way phase closure"))
    fig.add_trace(go.Scatter(x=rf[::phase_stride] / 1e6,
                             y=phase_cycles[::phase_stride], mode="lines",
                             name="Unwrapped phase", line_color="#2266bb"), row=1, col=1)
    if calibrations:
        center = [c["phase_reference_hz"] / 1e6 for c in calibrations]
        for field, label, color in (("mismatch_before_rms_deg", "Before", "#d04b32"),
                                    ("residual_rms_deg", "After", "#23856b")):
            fig.add_trace(go.Scatter(x=center, y=[c[field] for c in calibrations],
                                     mode="lines+markers", name=label,
                                     marker=dict(size=5), line_color=color), row=2, col=1)
    if closure:
        triples = closure.get("triples", [])
        fig.add_trace(go.Scatter(x=[(t["rf_low_hz"] + t["rf_high_hz"]) / 2e6
                                    for t in triples],
                                 y=[t["residual_phase_deg"] for t in triples],
                                 mode="lines+markers", name="Closure",
                                 marker=dict(size=5), line_color="#6c4ab0"), row=3, col=1)
    for row in (1, 2, 3):
        fig.update_xaxes(title_text="RF frequency (MHz)", row=row, col=1)
    fig.update_yaxes(title_text="Cycles", row=1, col=1)
    fig.update_yaxes(title_text="RMS degrees", type="log", row=2, col=1)
    fig.update_yaxes(title_text="Degrees", row=3, col=1)
    fig.update_layout(title="Subchirp phase recovery", height=950, hovermode="x unified")
    figures.append(("phase", "Phase recovery", fig))

    selected = sorted(set((0, len(results) // 2, len(results) - 1)))
    fig = make_subplots(rows=len(selected), cols=2, horizontal_spacing=0.1,
                        vertical_spacing=0.13,
                        subplot_titles=tuple(f"Segment {index + 1}: {kind}"
                                             for index in selected for kind in ("beat IQ", "spectrum")))
    for row, index in enumerate(selected, 1):
        segment = results[index]
        samples = segment["samples"]
        rate = segment["rx2_rate_hz"]
        count = min(len(samples), int(0.25e-3 * rate))
        t = np.arange(count) / rate * 1e3
        for values, label, color in ((samples.real, "I", "#2266bb"),
                                     (samples.imag, "Q", "#d04b32")):
            fig.add_trace(go.Scatter(x=t, y=values[:count], mode="lines",
                                     name=label, legendgroup=label, showlegend=row == 1,
                                     line=dict(color=color, width=1)), row=row, col=1)
        frequency, magnitude = beat_spectrum(samples, rate)
        band = np.abs(frequency) <= 100_000
        db = 20 * np.log10(np.maximum(magnitude[band], 1e-12) / (len(samples) / 2))
        fig.add_trace(go.Scatter(x=frequency[band] / 1e3, y=db, mode="lines",
                                 name="Spectrum", legendgroup="Spectrum",
                                 showlegend=row == 1, line_color="#6c4ab0"), row=row, col=2)
        fig.update_xaxes(title_text="Time (ms)", row=row, col=1)
        fig.update_yaxes(title_text="RX2 counts", row=row, col=1)
        fig.update_xaxes(title_text="Beat frequency (kHz)", row=row, col=2)
        fig.update_yaxes(title_text="dB re DMA count", row=row, col=2)
    fig.update_layout(title="Representative raw subchirps", height=350 * len(selected),
                      hovermode="closest")
    figures.append(("segments", "Raw subchirps", fig))

    nav = "".join(f'<a href="#{name}">{escape(label)}</a>' for name, label, _ in figures)
    summary = (f"<strong>Captured:</strong> {escape(captured_utc)} &nbsp; "
               f"<strong>RF:</strong> {frequency_hz[0] / 1e6:.3f}–"
               f"{frequency_hz[-1] / 1e6:.3f} MHz &nbsp; "
               f"<strong>Subchirps:</strong> {len(results)}")
    if distance is not None:
        medium_note = (f"round-trip air, n={air_refractive_index:g}"
                       if distance_medium == "air" else "one-way coax")
        summary += (f"<br><strong>Estimated distance resolution:</strong> "
                    f"{distance['distance_resolution_cm']:.1f} cm ({medium_note}); FFT display step "
                    f"{distance['display_step_cm']:.1f} cm. <strong>Calibration:</strong> "
                    f"{escape(calibration_source or 'provided')}.")
        if filter_info is not None:
            summary += (f" <strong>Software low-pass:</strong> full pass to "
                        f"{filter_info['pass_range_m']:g} m, stop at "
                        f"{filter_info['max_range_m']:g} m "
                        f"({filter_info['stop_frequency_hz'] / 1e3:.2f} kHz).")
        if not calibration_in_band:
            summary += (" <strong>Unverified absolute range:</strong> no RF subchirps "
                        "match the calibration; the board delay is extrapolated.")
        if distance_medium == "air":
            summary += (" The air axis assumes a reflected target (two propagation legs); "
                        "the coax loopback calibration does not establish an air-range zero.")
        if measurement is not None:
            summary += (" The range curve is phase-slope aligned to the matched raw "
                        "subchirps; its peak is not an independent length measurement.")
    else:
        summary += ("<br>Distance chart unavailable: supply --calibration with a "
                    "TX2/RX2 path-calibration JSON file.")
    sections = []
    for index, (name, label, figure) in enumerate(figures):
        figure.update_layout(template="plotly_white", margin=dict(l=70, r=30, t=80, b=55),
                             font=dict(family="Arial, sans-serif", size=13))
        chart = pio.to_html(figure, full_html=False, include_plotlyjs=index == 0,
                            config={"responsive": True, "scrollZoom": True,
                                    "displaylogo": False}, div_id=f"plot-{name}")
        sections.append(f'<section id="{name}"><h2>{escape(label)}</h2>{chart}</section>')
    page = ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            "<title>TX2/RX2 FMCW interactive results</title>"
            "<style>body{font-family:Arial,sans-serif;margin:0;background:#f3f6fa;color:#172436}"
            "header{background:#172436;color:white;padding:18px 28px}header h1{margin:0 0 8px}"
            "header p{margin:0;line-height:1.6}nav{display:flex;gap:16px;flex-wrap:wrap;"
            "background:#e2eaf3;padding:12px 28px;position:sticky;top:0;z-index:10}"
            "nav a{color:#14528a;text-decoration:none;font-weight:bold}"
            "section{background:white;margin:22px auto;padding:18px 22px;max-width:1450px;"
            "border-radius:8px;box-shadow:0 1px 8px #d6deea}h2{margin:0 0 8px}"
            ".note{font-size:0.9em;color:#405066}</style></head><body>"
            f"<header><h1>TX2/RX2 FMCW results</h1><p>{summary}</p>"
            "<p class=\"note\" style=\"color:#dbe8f3\">Zoom, pan, hover, and toggle traces "
            "with the chart controls. The wideband beat is phase-stitched from retuned "
            "subchirps, not one uninterrupted RF transmission.</p></header>"
            f"<nav>{nav}</nav>{''.join(sections)}</body></html>")
    path = output / "rx2_interactive.html"
    path.write_text(page)
    return path
