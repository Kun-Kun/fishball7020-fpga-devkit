"""Known-delay check for the FMCW path calibration phase fit."""

import unittest

import numpy as np

from fmcw_path_calibration import phase_delay_ns


class PathCalibrationTest(unittest.TestCase):
    def test_recovers_delay_difference_from_phase_slope(self):
        frequency = 1e9 + np.arange(8192) * 4000.0
        short = np.exp(1j * (0.7 - 2 * np.pi * frequency * 655e-9))
        long = np.exp(1j * (-1.1 - 2 * np.pi * frequency * 678.5e-9))
        rng = np.random.default_rng(27)
        short += 0.003 * (rng.normal(size=frequency.size) +
                          1j * rng.normal(size=frequency.size))
        long += 0.003 * (rng.normal(size=frequency.size) +
                         1j * rng.normal(size=frequency.size))
        short_delay, _ = phase_delay_ns(frequency, short, np.ones(len(short), dtype=bool))
        added_delay, _ = phase_delay_ns(frequency, long * np.conj(short),
                                        np.ones(len(short), dtype=bool))
        self.assertAlmostEqual(short_delay, 655.0, delta=0.02)
        self.assertAlmostEqual(added_delay, 23.5, delta=0.02)


if __name__ == "__main__":
    unittest.main()
