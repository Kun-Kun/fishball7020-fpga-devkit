"""Register encoding and transport checks for the ADF4159 web API."""

import math
import unittest
from unittest.mock import patch

import adf4159_web as api


class RegisterTests(unittest.TestCase):
    def test_beat_path_and_tx1_dc_validation(self):
        self.assertEqual(api.beat_path_settings({}), ("tx2_rx2", 16000))
        self.assertEqual(api.beat_path_settings({"beat_path": "tx1_rx1",
                                                 "tx1_dc_amplitude": 8192}),
                         ("tx1_rx1", 8192))
        for body in ({"beat_path": "unknown"}, {"tx1_dc_amplitude": 17},
                     {"tx1_dc_amplitude": 0}, {"tx1_dc_amplitude": True}):
            with self.assertRaises(api.BadRequest):
                api.beat_path_settings(body)

    def test_beat_window_and_start_trim_validation(self):
        self.assertEqual(api.beat_analysis_settings({}, 1000), ("hann", 0))
        self.assertEqual(api.beat_analysis_settings({"fft_window": "blackman_harris",
                                                     "discard_samples": 512}, 1000),
                         ("blackman_harris", 512))
        for body in ({"fft_window": "unknown"}, {"discard_samples": -1},
                     {"discard_samples": 1921}, {"discard_samples": True}):
            with self.assertRaises(api.BadRequest):
                api.beat_analysis_settings(body, 1000)

    def test_tx_probe_frequency_validation(self):
        self.assertEqual(api.tx_probe_settings({"tx_waveform": "tone",
                                                "tx_tone_frequency_hz": -1_250_000}),
                         ("tone", -1_250_000))
        self.assertEqual(api.tx_probe_settings({"tx_waveform": "tone"}),
                         ("tone", 1_000_000))
        with self.assertRaises(api.BadRequest):
            api.tx_probe_settings({"tx_waveform": "tone", "tx_tone_frequency_hz": 16_000_000})
        with self.assertRaises(api.BadRequest):
            api.tx_probe_settings({"tx_waveform": "tone", "tx_tone_frequency_hz": True})

    def test_measured_4_5_ghz_configuration(self):
        config = api.cw_words({"frequency_hz": 4_500_000_000})
        self.assertEqual(config["words_hex"], [
            "0x00000007", "0x00000006", "0x00800006",
            "0x00000005", "0x00800005", "0x00180104", "0x00180144",
            "0x00000003", "0x0000800A", "0x00000001", "0x30168000",
        ])
        self.assertEqual(config["actual_hz"], 4_500_000_000)

    def test_fractional_low_edge_matches_measured_words(self):
        config = api.cw_words({"frequency_hz": 3_905_000_000})
        self.assertEqual(config["words_hex"][-2:], ["0x0CCD0001", "0x30138660"])
        self.assertLess(abs(config["actual_hz"] - 3_905_000_000), 2)

    def test_pfd_limit_and_integer_n(self):
        with self.assertRaisesRegex(api.BadRequest, "PFD frequency"):
            api.cw_words({"frequency_hz": 4_500_000_000, "reference_hz": 120_000_000})
        with self.assertRaisesRegex(api.BadRequest, "integer N"):
            api.cw_words({"frequency_hz": 500_000_000})

    def test_raw_words_preserve_order_and_reject_shell_text(self):
        self.assertEqual(api.raw_words({"words": ["0x3", "0000800A", "30168000"]}),
                         [3, 0x800A, 0x30168000])
        with self.assertRaises(api.BadRequest):
            api.raw_words({"words": ["0x3; reboot"]})
        with self.assertRaises(api.BadRequest):
            api.host_name("pluto.local;reboot")

    def test_one_spi_transfer_per_word(self):
        with patch.object(api, "board_shell") as remote:
            api.write_registers("pluto.local", [3, 0x800A, 0x30168000])
        script = remote.call_args.args[1]
        self.assertEqual(script.count("xxd -r -p > /dev/spidev1.0"), 3)
        self.assertIn("'00000003'", script)
        self.assertIn("'30168000'", script)

    def test_ramp_matches_measured_50_mhz_probe_and_fmcw_math(self):
        config = api.ramp_words({
            "start_frequency_hz": 4_500_000_000, "span_hz": 50_000_000,
            "chirp_time_us": 1000, "steps": 200,
        })
        self.assertEqual(config["words_hex"], [
            "0x00000007", "0x00000646", "0x00800006",
            "0x00128F65", "0x00800005", "0x00180084", "0x001800C4",
            "0x00020003", "0x00008FAA", "0x00000001", "0xB0168000",
        ])
        self.assertAlmostEqual(config["actual_vco_span_hz"], 50_001_144.409, places=2)
        self.assertAlmostEqual(config["actual_rf_span_hz"], config["actual_vco_span_hz"] / 2)
        self.assertAlmostEqual(config["actual_chirp_time_us"], 1000)
        self.assertAlmostEqual(config["range_resolution_m"], 299_792_458 / config["actual_vco_span_hz"])
        self.assertAlmostEqual(config["single_chirp_fft_bin_hz"], 1000)

    def test_triangle_and_ramp_bounds(self):
        params = {"start_frequency_hz": 4_500_000_000,
                  "span_hz": 25_000_000, "chirp_time_us": 1000,
                  "waveform": "triangle"}
        config = api.ramp_words(params)
        self.assertEqual(config["words"][7] & 0xC00, 0x400)
        self.assertAlmostEqual(config["full_cycle_time_us"], 2000)
        with self.assertRaisesRegex(api.BadRequest, "upper limit"):
            api.ramp_words({**params, "start_frequency_hz": 7_990_000_000})
        with self.assertRaisesRegex(api.BadRequest, "tri-state"):
            api.ramp_words({**params, "tri_state": True})
        with self.assertRaisesRegex(api.BadRequest, "CLK1/CLK2"):
            api.ramp_words({**params, "chirp_time_us": 100, "steps": 1_000_000})

    def test_single_sawtooth_trigger_and_completion_muxout(self):
        config = api.ramp_words({
            "start_frequency_hz": 4_500_000_000, "span_hz": 50_000_000,
            "chirp_time_us": 1000, "steps": 200,
            "waveform": "single_sawtooth",
        })
        words = config["words"]
        self.assertTrue(config["triggered"])
        self.assertTrue(config["ramp_complete_muxout"])
        self.assertEqual(words[0], 0x00100007)  # R7: TXDATA trigger
        self.assertEqual(words[7] & 0xC00, 0x800)  # R3: single sawtooth
        self.assertEqual(words[5] & 0x03E00000, 0x00600000)  # R4: completion MUXOUT
        self.assertEqual(words[10] & 0xF8000000, 0xF8000000)  # R0: ramp + MUXOUT selector

    def test_span_above_200_mhz_and_vco_upper_edge(self):
        params = {"start_frequency_hz": 4_500_000_000,
                  "span_hz": 500_000_000, "chirp_time_us": 1000}
        wide = api.ramp_words(params)
        self.assertAlmostEqual(wide["actual_vco_span_hz"], 500_000_000, delta=100_000)
        edge = api.ramp_words({**params, "span_hz": 3_500_000_000})
        self.assertLessEqual(edge["actual_start_hz"] + edge["actual_vco_span_hz"], 8_000_000_000)
        with self.assertRaisesRegex(api.BadRequest, "upper limit"):
            api.ramp_words({**params, "span_hz": 3_500_100_000})


class SpectrumTests(unittest.TestCase):
    def test_expected_tone_is_detected(self):
        import numpy as np

        fs = 30_720_000
        t = np.arange(65536)
        signal = 100 * np.exp(2j * np.pi * 1_000_000 * t / fs)
        iq = np.column_stack((signal.real, signal.imag)).astype("<i2")
        result = api.analyze_capture(iq.tobytes(), fs, 4_499_000_000, 1_000_000)
        self.assertTrue(result["tone_found"])
        self.assertLess(abs(result["estimated_rf_hz"] - 4_500_000_000), 1000)
        self.assertTrue(math.isfinite(result["rms_dbfs"]))
        self.assertEqual(len(result["spectrum_db_relative"]), 512)


if __name__ == "__main__":
    unittest.main()
