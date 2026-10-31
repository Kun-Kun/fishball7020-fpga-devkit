"""Known-distance check for the calibrated FMCW range axis."""

import unittest

import numpy as np

from fmcw_interactive import distance_profile, low_pass_range
from fmcw_path_calibration import LIGHT_SPEED_M_PER_S


class DistanceProfileTest(unittest.TestCase):
    def test_range_low_pass_preserves_near_tone_and_rejects_far_tone(self):
        sample_rate = 1_000_000
        count = 100_000
        samples = np.arange(count)
        near = np.exp(-2j * np.pi * 3_000 * samples / sample_rate)
        far = np.exp(-2j * np.pi * 22_500 * samples / sample_rate)
        filtered, details = low_pass_range(near + 0.7 * far, sample_rate,
                                           30_000_000_000, 2.5, 5.0, 100.0)
        interior = slice(10_000, -10_000)
        self.assertLess(np.max(np.abs(filtered[interior] - near[interior])), 1e-3)
        self.assertAlmostEqual(details["pass_range_m"], 90.0)
        self.assertAlmostEqual(details["stop_frequency_hz"], 15_075.0)

    def test_round_trip_air_range_uses_refractive_index(self):
        sample_rate = 7_500_000
        chirp_slope = 30_000_000_000
        refractive_index = 1.0003
        delay_ns_per_meter = 2e9 * refractive_index / LIGHT_SPEED_M_PER_S
        fixed_delay_ns = 653.63
        target_range_m = 5.0
        delay_s = (fixed_delay_ns + delay_ns_per_meter * target_range_m) * 1e-9
        samples = np.arange(250_000)
        beat = np.exp(-2j * np.pi * chirp_slope * delay_s * samples / sample_rate)
        result = distance_profile(beat, sample_rate, chirp_slope, 1e8,
                                  fixed_delay_ns, delay_ns_per_meter)
        self.assertAlmostEqual(result["fft_peak_distance_cm"], 500.0,
                               delta=result["distance_resolution_cm"] / 2)
        self.assertAlmostEqual(result["distance_resolution_cm"],
                               100 * LIGHT_SPEED_M_PER_S / (2 * refractive_index * 1e8))

    def test_beat_tone_maps_to_one_way_coax_length(self):
        sample_rate = 7_500_000
        chirp_slope = 30_000_000_000
        fixed_delay_ns = 653.63
        coax_delay_ns_per_meter = 5.004
        length_m = 5.0
        delay_s = (fixed_delay_ns + coax_delay_ns_per_meter * length_m) * 1e-9
        samples = np.arange(250_000)
        beat = np.exp(-2j * np.pi * chirp_slope * delay_s * samples / sample_rate)
        result = distance_profile(beat, sample_rate, chirp_slope, 1e9,
                                  fixed_delay_ns, coax_delay_ns_per_meter)
        self.assertTrue(np.all(np.diff(result["distance_cm"]) > 0))
        self.assertAlmostEqual(result["distance_resolution_cm"], 20.0, delta=0.1)
        self.assertAlmostEqual(result["fft_peak_distance_cm"], 500.0,
                               delta=result["distance_resolution_cm"] / 2)


if __name__ == "__main__":
    unittest.main()
