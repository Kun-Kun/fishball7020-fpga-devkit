"""Synthetic phase-reference test with known delay and independent LO phases."""

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import numpy as np

from fmcw_phase import _overlap, plot_phase, recover_phase


class PhaseRecoveryTest(unittest.TestCase):
    def test_seven_segment_closure_plot_handles_multiple_triples(self):
        samples_per_chirp = 2048
        segments = []
        for index in range(7):
            low = 500_000_000 + index * 12_000_000
            high = low + 32_000_000
            frequency = low + (high - low) * np.arange(samples_per_chirp) / samples_per_chirp
            taper = np.sin(np.linspace(0, np.pi / 2, 24, endpoint=False)) ** 2
            envelope = np.ones(samples_per_chirp)
            envelope[:24] = taper
            envelope[-24:] = taper[::-1]
            one = envelope * np.exp(1j * (-2 * np.pi * frequency * 0.66e-6 + 0.4 * index))
            segments.append({"rf_low_hz": low, "rf_high_hz": high,
                             "chirp_samples": samples_per_chirp * 8,
                             "samples": np.tile(one, 8)})
        profiles, calibrations, closure, stitched = recover_phase(segments)
        self.assertGreater(closure["count"], 1)
        with TemporaryDirectory() as directory:
            plot_phase(profiles, calibrations, closure, stitched, Path(directory))
            self.assertTrue((Path(directory) / "rx2_phase_recovery.png").exists())

    def test_three_overlapping_chirps_share_one_phase_reference(self):
        rf = ((1_000_000_000, 1_032_000_000),
              (1_012_000_000, 1_044_000_000),
              (1_024_000_000, 1_055_000_000))
        samples_per_chirp = 8192
        rng = np.random.default_rng(7020)
        segments = []
        for (low, high), lo_phase, error_delay, shift in zip(
                rf, (0.0, 1.7, -1.2), (0.0, 0.5e-9, -0.3e-9), (317, 2011, 6330)):
            f = low + (high - low) * np.arange(samples_per_chirp) / samples_per_chirp
            envelope = np.ones(samples_per_chirp)
            edge = 85
            taper = np.sin(np.linspace(0, np.pi / 2, edge, endpoint=False)) ** 2
            envelope[:edge] = taper
            envelope[-edge:] = taper[::-1]
            phase = (-2 * np.pi * (f - 1e9) * 0.67e-6 + lo_phase +
                     2 * np.pi * (f - 1.03e9) * error_delay)
            beat = 100 * envelope * np.exp(1j * phase)
            one = np.roll(beat, shift)
            samples = np.tile(one, 8) + rng.normal(0, 0.25, 8 * samples_per_chirp) + \
                1j * rng.normal(0, 0.25, 8 * samples_per_chirp)
            segments.append({"rf_low_hz": low, "rf_high_hz": high,
                             "chirp_samples": samples_per_chirp * 8,
                             "samples": samples})

        profiles, calibration, closure, stitched = recover_phase(segments)
        self.assertEqual(len(calibration), 2)
        self.assertTrue(all(pair["coherence_after"] > 0.999 for pair in calibration))
        self.assertTrue(all(pair["residual_rms_deg"] < 0.5 for pair in calibration))
        self.assertLess(abs(closure["residual_phase_deg"]), 1.0)
        self.assertGreater(closure["coherence"], 0.999)
        self.assertGreater(stitched["valid"].sum(), 13_000)
        for first, second in ((0, 1), (1, 2)):
            _, a, b = _overlap(profiles[first], profiles[second])
            mismatch = np.angle(a * np.conj(b))
            self.assertLess(float(np.std(mismatch)), np.deg2rad(0.5))


if __name__ == "__main__":
    unittest.main()
