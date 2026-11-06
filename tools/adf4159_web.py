#!/usr/bin/env python3
"""Local web UI and JSON API for an ADF4159 connected to Pluto PL SPI.

Run on the development PC, not on Pluto. The board needs the JP5 SPI firmware,
SSH access as root, /dev/spidev1.0 and xxd. No ADF register readback is assumed.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import math
import re
import subprocess
import threading
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


MODULUS = 1 << 25
SPI_DEVICE = "/dev/spidev1.0"
PHY = "/sys/bus/iio/devices/iio:device0"
PAGE = Path(__file__).with_suffix(".html")
HOSTNAME = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\Z")
SAMPLE_RATE = re.compile(rb"sample_rate_hz=(\d+)")
LIGHT_SPEED = 299_792_458.0
BEAT_SAMPLE_RATE = 7_680_000


class BadRequest(ValueError):
    pass


class BoardError(RuntimeError):
    pass


def host_name(value: object) -> str:
    if not isinstance(value, str) or not value or len(value) > 253:
        raise BadRequest("host must be a Pluto IPv4 address or hostname")
    try:
        return str(ipaddress.IPv4Address(value))
    except ipaddress.AddressValueError:
        pass
    if all(part.isdigit() for part in value.split(".")):
        raise BadRequest("invalid Pluto IPv4 address")
    if not HOSTNAME.fullmatch(value) or ".." in value or any(
        label.startswith("-") or label.endswith("-") for label in value.split(".")
    ):
        raise BadRequest("invalid Pluto hostname")
    return value


def integer(body: dict, key: str, minimum: int, maximum: int, default: int | None = None) -> int:
    value = body.get(key, default)
    if type(value) is not int or not minimum <= value <= maximum:
        raise BadRequest(f"{key} must be an integer from {minimum} to {maximum}")
    return value


def boolean(body: dict, key: str, default: bool = False) -> bool:
    value = body.get(key, default)
    if type(value) is not bool:
        raise BadRequest(f"{key} must be true or false")
    return value


def cw_words(body: dict) -> dict:
    """Build the measured CW register sequence, including fractional N."""
    frequency_hz = integer(body, "frequency_hz", 500_000_000, 13_000_000_000)
    reference_hz = integer(body, "reference_hz", 10_000_000, 260_000_000, 100_000_000)
    r_counter = integer(body, "r_counter", 1, 31, 1)
    pump = integer(body, "charge_pump_code", 0, 15, 0)
    polarity = body.get("polarity", "negative")
    if polarity not in ("negative", "positive"):
        raise BadRequest("polarity must be negative or positive")
    tri_state = boolean(body, "tri_state")
    pfd_hz = reference_hz / r_counter
    if pfd_hz > 110_000_000:
        raise BadRequest("PFD frequency must be at most 110 MHz; increase R")

    # N = INT + FRAC/2^25. Round to the nearest fractional step without floats.
    scaled = (frequency_hz * r_counter * MODULUS + reference_hz // 2) // reference_hz
    n, frac = divmod(scaled, MODULUS)
    prescaler_8_9 = frequency_hz > 8_000_000_000
    minimum_n = 75 if prescaler_8_9 else 23
    if not minimum_n <= n <= 4095:
        raise BadRequest(f"integer N must be {minimum_n} to 4095 at this PFD frequency")

    r3 = 0x00000003 | (0x40 if polarity == "positive" else 0) | (0x10 if tri_state else 0)
    r2 = (pump << 24) | (0x400000 if prescaler_8_9 else 0) | (r_counter << 15) | 0xA
    r1 = ((frac & 0x1FFF) << 15) | 1
    # 0x30000000 selects digital lock detect on MUXOUT, although it may be unwired.
    r0 = 0x30000000 | (n << 15) | ((frac >> 13) << 3)
    # Datasheet power-up sequence: R7, both banks of R6/R5/R4, then R3..R0.
    # The inactive ramp-bank values here match the evaluation software's
    # documented defaults. R0 disables ramping for this CW operation.
    words = [
        0x00000007,
        0x00000006, 0x00800006,
        0x00000005, 0x00800005,
        0x00180104, 0x00180144,
        r3, r2, r1, r0,
    ]
    actual_hz = scaled * reference_hz / (r_counter * MODULUS)
    return {
        "words": words,
        "words_hex": [f"0x{word:08X}" for word in words],
        "frequency_hz": frequency_hz,
        "actual_hz": actual_hz,
        "reference_hz": reference_hz,
        "pfd_hz": pfd_hz,
        "r_counter": r_counter,
        "integer_n": n,
        "fractional_n": frac,
        "charge_pump_code": pump,
        "polarity": polarity,
        "tri_state": tri_state,
        "prescaler": "8/9" if prescaler_8_9 else "4/5",
    }


def ramp_words(body: dict) -> dict:
    """Plan an ADF4159 continuous ramp with quantized, achievable settings."""
    start = integer(body, "start_frequency_hz", 4_000_000_000, 8_000_000_000)
    span = integer(body, "span_hz", 100_000, 4_000_000_000)
    period_us = integer(body, "chirp_time_us", 100, 100_000)
    steps = integer(body, "steps", 2, 1_048_575, 200)
    reference = integer(body, "reference_hz", 10_000_000, 260_000_000, 100_000_000)
    r = integer(body, "r_counter", 1, 31, 1)
    pump = integer(body, "charge_pump_code", 0, 15, 0)
    polarity = body.get("polarity", "negative")
    waveform = body.get("waveform", "sawtooth")
    tri_state = boolean(body, "tri_state")
    if waveform not in ("sawtooth", "triangle", "single_sawtooth"):
        raise BadRequest("waveform must be sawtooth, triangle or single_sawtooth")
    if polarity not in ("negative", "positive"):
        raise BadRequest("polarity must be negative or positive")
    if tri_state:
        raise BadRequest("charge pump tri-state must be off for an active ramp")
    if start + span > 8_000_000_000:
        raise BadRequest("start plus span exceeds the HMC586 8 GHz upper limit")
    pfd = reference / r
    if pfd > 110_000_000:
        raise BadRequest("PFD frequency must be at most 110 MHz; increase R")
    scaled = (start * r * MODULUS + reference // 2) // reference
    n, frac = divmod(scaled, MODULUS)
    actual_start = scaled * reference / (r * MODULUS)
    if not 23 <= n <= 4095:
        raise BadRequest("integer N must be 23 to 4095 with the 4/5 prescaler")
    target_ticks = period_us * 1e-6 * pfd / steps
    clk2 = max(1, math.ceil(target_ticks / 4095))
    clk1 = math.floor(target_ticks / clk2 + 0.5)
    if clk1 < 1 or clk1 > 4095 or clk2 > 4095 or (clk1 == 1 and clk2 == 1):
        raise BadRequest("chirp time and steps cannot be represented by CLK1/CLK2")
    f_res = pfd / MODULUS
    desired_step = span / steps
    chosen = None
    for dev_offset in range(16):
        dev = math.floor(desired_step / (f_res * (1 << dev_offset)) + 0.5)
        while dev > 0 and actual_start + steps * f_res * dev * (1 << dev_offset) > 8_000_000_000:
            dev -= 1
        if 1 <= dev <= 32767:
            chosen = dev, dev_offset
            break
    if chosen is None:
        raise BadRequest("ramp step cannot be represented by DEV/DEV_OFFSET")
    dev, dev_offset = chosen
    actual_step = f_res * dev * (1 << dev_offset)
    actual_span = steps * actual_step
    actual_time = steps * clk1 * clk2 / pfd
    rf_span = actual_span / 2  # AD9361 external LO divide-by-two
    slope = rf_span / actual_time
    single = waveform == "single_sawtooth"
    r3 = (0x00020003 | (0x400 if waveform == "triangle" else 0) |
          (0x800 if single else 0) |
          (0x40 if polarity == "positive" else 0))
    r2 = (pump << 24) | (r << 15) | (clk1 << 3) | 0xA
    words = [
        0x00100007 if single else 7, (steps << 3) | 6, 0x00800006,
        (dev_offset << 19) | (dev << 3) | 5, 0x00800005,
        (0x00780000 if single else 0x00180000) | (clk2 << 7) | 4,
        (0x00780000 if single else 0x00180000) | (clk2 << 7) | 0x40 | 4,
        r3, r2, ((frac & 0x1FFF) << 15) | 1,
        (0xF8000000 if single else 0xB0000000) | (n << 15) | ((frac >> 13) << 3),
    ]
    return {
        "words": words, "words_hex": [f"0x{w:08X}" for w in words],
        "waveform": waveform, "start_frequency_hz": start, "requested_span_hz": span,
        "triggered": single, "ramp_complete_muxout": single,
        "actual_start_hz": actual_start,
        "actual_vco_span_hz": actual_span, "actual_rf_span_hz": rf_span,
        "actual_chirp_time_us": actual_time * 1e6,
        "full_cycle_time_us": actual_time * 1e6 * (2 if waveform == "triangle" else 1),
        "pfd_hz": pfd, "frequency_resolution_hz": f_res,
        "steps": steps, "clk1": clk1, "clk2": clk2,
        "dev": dev, "dev_offset": dev_offset,
        "vco_step_hz": actual_step, "rf_step_hz": actual_step / 2,
        "rf_slope_hz_per_s": slope,
        "range_resolution_m": LIGHT_SPEED / (2 * rf_span),
        "beat_hz_per_m_air": 2 * slope / LIGHT_SPEED,
        "coax_30cm_beat_hz": slope * 0.3 / (0.667 * LIGHT_SPEED),
        "single_chirp_fft_bin_hz": 1 / actual_time,
        "ideal_max_unaliased_range_m": LIGHT_SPEED * (BEAT_SAMPLE_RATE / 2) / (2 * slope),
        "rx2_sample_rate_hz": BEAT_SAMPLE_RATE,
        "reference_hz": reference, "r_counter": r,
        "charge_pump_code": pump, "polarity": polarity,
    }


def raw_words(body: dict) -> list[int]:
    values = body.get("words")
    if not isinstance(values, list) or not 1 <= len(values) <= 64:
        raise BadRequest("words must contain 1 to 64 register words")
    result = []
    for value in values:
        if not isinstance(value, str) or not re.fullmatch(r"(?:0[xX])?[0-9a-fA-F]{1,8}", value):
            raise BadRequest("each word must be 1 to 8 hexadecimal digits")
        result.append(int(value, 16))
    return result


def tx_probe_settings(body: dict) -> tuple[str, int]:
    waveform = body.get("tx_waveform", "chirp")
    if waveform not in ("tone", "chirp"):
        raise BadRequest("tx_waveform must be tone or chirp")
    frequency = integer(body, "tx_tone_frequency_hz", -15_000_000, 15_000_000,
                        1_000_000 if waveform == "tone" else 0)
    return waveform, frequency


def beat_analysis_settings(body: dict, actual_chirp_time_us: float) -> tuple[str, int]:
    window = body.get("fft_window", "hann")
    if window not in ("rectangular", "hann", "blackman_harris"):
        raise BadRequest("fft_window must be rectangular, hann or blackman_harris")
    nominal_samples = math.floor(actual_chirp_time_us * BEAT_SAMPLE_RATE / 1_000_000 + 0.5)
    discarded = integer(body, "discard_samples", 0, nominal_samples // 4, 0)
    return window, discarded


def board_shell(host: str, script: str, timeout: int = 20) -> subprocess.CompletedProcess[bytes]:
    argv = [
        "ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
        "-o", "ConnectionAttempts=1", "-o", "StrictHostKeyChecking=accept-new",
        f"root@{host}", "sh", "-s",
    ]
    try:
        result = subprocess.run(argv, input=script.encode("ascii"), capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise BoardError(f"Pluto did not finish within {timeout} seconds") from exc
    except OSError as exc:
        raise BoardError(f"could not start ssh: {exc}") from exc
    if result.returncode:
        reason = result.stderr.decode("utf-8", "replace").strip()[-600:]
        raise BoardError(reason or f"Pluto command exited {result.returncode}")
    return result


def write_registers(host: str, words: list[int]) -> None:
    # Each redirection opens spidev anew, so every 32-bit word gets its own LE
    # rising edge. The hex strings are generated from validated integers.
    script = "set -eu\ntest -c /dev/spidev1.0\ncommand -v xxd >/dev/null\n"
    script += "\n".join(
        f"printf '%s' '{word:08x}' | xxd -r -p > {SPI_DEVICE}" for word in words
    ) + "\nrm -f /tmp/adf4159-web-last.json\n"
    board_shell(host, script)


def board_cgi(host: str, mode: str, body: dict) -> dict:
    """Use the installed native board service for its local DMA beat capture."""
    request = urllib.request.Request(
        f"http://{host}:8080/cgi-bin/adf4159.cgi?mode={mode}",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            message = json.load(exc).get("error", str(exc))
        except (ValueError, OSError):
            message = str(exc)
        raise BoardError(message) from exc
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        raise BoardError(f"board {mode} service on port 8080 is unavailable: {exc}") from exc


def probe_board(host: str) -> dict:
    result = board_shell(
        host,
        "set -eu\ntest -c /dev/spidev1.0\ncommand -v xxd >/dev/null\n"
        f"cat {PHY}/out_altvoltage0_RX_LO_frequency\n"
        f"cat {PHY}/in_voltage0_gain_control_mode\n"
        f"cat {PHY}/out_altvoltage0_RX_LO_external\n"
        f"cat {PHY}/out_altvoltage1_TX_LO_external\n"
        f"cat {PHY}/ensm_mode\n",
    )
    lines = result.stdout.decode("ascii", "replace").splitlines()
    if len(lines) != 5:
        raise BoardError("unexpected board status response")
    return {"connected": True, "spi_device": SPI_DEVICE,
            "rx_lo_hz": int(lines[0]), "rx_gain_mode": lines[1],
            "rx_external_lo": lines[2] == "1", "tx_external_lo": lines[3] == "1",
            "ensm_mode": lines[4]}


def capture_rx1(host: str, lo_hz: int, samples: int = 65536) -> tuple[bytes, int]:
    # The trap restores the receiver on success and on a remote command error.
    # This operation temporarily retunes RX1, so callers serialize it with writes.
    script = f"""set -eu
sys={PHY}
old_lo=$(cat "$sys/out_altvoltage0_RX_LO_frequency")
old_mode=$(cat "$sys/in_voltage0_gain_control_mode")
old_gain=$(cat "$sys/in_voltage0_hardwaregain")
restore() {{
  printf '%s\\n' "$old_lo" > "$sys/out_altvoltage0_RX_LO_frequency"
  printf '%s\\n' "$old_mode" > "$sys/in_voltage0_gain_control_mode"
  if [ "$old_mode" = manual ]; then
    printf '%s\\n' "$old_gain" > "$sys/in_voltage0_hardwaregain"
  fi
}}
trap restore EXIT
printf '%s\\n' manual > "$sys/in_voltage0_gain_control_mode"
printf '%s\\n' 0 > "$sys/in_voltage0_hardwaregain"
printf '%s\\n' {lo_hz} > "$sys/out_altvoltage0_RX_LO_frequency"
sample_rate=$(cat "$sys/in_voltage_sampling_frequency")
printf 'sample_rate_hz=%s\\n' "$sample_rate" >&2
sleep 1
iio_readdev -u local: -s {samples} cf-ad9361-lpc voltage0 voltage1
"""
    result = board_shell(host, script, timeout=30)
    match = SAMPLE_RATE.search(result.stderr)
    if not match:
        raise BoardError("RX capture did not report its sample rate")
    if len(result.stdout) != samples * 4:
        raise BoardError(f"RX capture returned {len(result.stdout)} bytes; expected {samples * 4}")
    return result.stdout, int(match.group(1))


def analyze_capture(raw: bytes, sample_rate_hz: int, lo_hz: int, expected_offset_hz: int) -> dict:
    import numpy as np

    iq = np.frombuffer(raw, dtype="<i2").reshape(-1, 2).astype(np.float64)
    signal = iq[:, 0] + 1j * iq[:, 1]
    rms = float(np.sqrt(np.mean(np.abs(signal) ** 2)))
    spectrum = np.fft.fftshift(np.fft.fft(signal * np.hanning(len(signal))))
    freq = np.fft.fftshift(np.fft.fftfreq(len(signal), 1 / sample_rate_hz))
    power = np.abs(spectrum) ** 2
    valid = np.abs(freq) > 100_000
    near = np.abs(freq - expected_offset_hz) <= 250_000
    if not np.any(near):
        raise BadRequest("expected tone is outside the sampled bandwidth")
    selected = np.flatnonzero(near)
    peak = int(selected[np.argmax(power[near])])
    prominence = 10 * math.log10(float(power[peak] / np.median(power[valid])))
    bins = 512
    envelope = 10 * np.log10(np.maximum(power.reshape(bins, -1).max(axis=1), 1e-30))
    envelope -= envelope.max()
    return {
        "sample_count": len(signal), "sample_rate_hz": sample_rate_hz,
        "rx_lo_hz": lo_hz, "rx_gain_db": 0,
        "rms_dbfs": round(20 * math.log10(rms / 2048), 2),
        "tone_found": prominence >= 25,
        "tone_offset_hz": round(float(freq[peak])),
        "estimated_rf_hz": round(lo_hz + float(freq[peak])),
        "tone_over_median_db": round(prominence, 2),
        "clipped_samples": int(np.count_nonzero(np.any(np.abs(iq) >= 2047, axis=1))),
        "spectrum_db_relative": np.round(envelope, 1).tolist(),
        "spectrum_min_hz": -sample_rate_hz / 2,
        "spectrum_max_hz": sample_rate_hz / 2,
    }


class App(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int]):
        super().__init__(address, Handler)
        self.operation_lock = threading.Lock()
        self.last_write: dict[str, dict] = {}


class Handler(BaseHTTPRequestHandler):
    server: App

    def json_reply(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = urlsplit(self.path)
        if path.path == "/":
            body = PAGE.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path.path != "/api/status":
            self.json_reply(404, {"error": "not found"})
            return
        try:
            host = host_name(parse_qs(path.query).get("host", [""])[0])
            status = probe_board(host)
            status["host"] = host
            status["last_write_by_this_server"] = self.server.last_write.get(host)
            self.json_reply(200, status)
        except (BadRequest, BoardError, ValueError) as exc:
            self.json_reply(400 if isinstance(exc, BadRequest) else 502, {"error": str(exc)})

    def do_POST(self) -> None:
        path = urlsplit(self.path).path
        if path not in ("/api/cw", "/api/plan", "/api/ramp", "/api/beat", "/api/stream", "/api/gate", "/api/tx2", "/api/registers", "/api/measure"):
            self.json_reply(404, {"error": "not found"})
            return
        try:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError as exc:
                raise BadRequest("invalid Content-Length") from exc
            if not 1 <= length <= 16384:
                raise BadRequest("JSON body must be 1 to 16384 bytes")
            try:
                body = json.loads(self.rfile.read(length))
            except json.JSONDecodeError as exc:
                raise BadRequest("invalid JSON body") from exc
            if not isinstance(body, dict):
                raise BadRequest("JSON body must be an object")
            host = host_name(body.get("host"))
            if path == "/api/cw":
                config = cw_words(body)
                with self.server.operation_lock:
                    write_registers(host, config["words"])
                    self.server.last_write[host] = {
                        "at_utc": datetime.now(timezone.utc).isoformat(),
                        "mode": "cw", "words": config["words_hex"],
                        "frequency_hz": config["frequency_hz"],
                    }
                config.pop("words")
                self.json_reply(200, {"host": host, "applied": config})
            elif path == "/api/plan":
                config = ramp_words(body)
                config.pop("words")
                self.json_reply(200, {"host": host, "planned": config})
            elif path == "/api/ramp":
                config = ramp_words(body)
                with self.server.operation_lock:
                    if config["triggered"]:
                        result = board_cgi(host, "ramp", {k: v for k, v in body.items() if k != "host"})
                    else:
                        write_registers(host, config["words"])
                        config.pop("words")
                        result = {"host": host, "applied": config}
                    self.server.last_write[host] = {
                        "at_utc": datetime.now(timezone.utc).isoformat(),
                        "mode": "single_ramp" if config["triggered"] else "ramp",
                        "words": config["words_hex"],
                        "frequency_hz": config["start_frequency_hz"],
                        "span_hz": config["actual_vco_span_hz"],
                    }
                self.json_reply(200, result)
            elif path == "/api/beat":
                config = ramp_words(body)
                tx_probe_settings(body)
                beat_analysis_settings(body, config["actual_chirp_time_us"])
                if not 500 <= config["actual_chirp_time_us"] <= 2000:
                    raise BadRequest("beat capture supports a 0.5 to 2 ms ramp leg")
                with self.server.operation_lock:
                    result = board_cgi(host, "beat", {k: v for k, v in body.items() if k != "host"})
                self.json_reply(200, result)
            elif path == "/api/stream":
                config = ramp_words(body)
                tx_probe_settings(body)
                beat_analysis_settings(body, config["actual_chirp_time_us"])
                if not config["triggered"]:
                    raise BadRequest("streaming requires single_sawtooth waveform")
                if not 500 <= config["actual_chirp_time_us"] <= 2000:
                    raise BadRequest("beat capture supports a 0.5 to 2 ms ramp leg")
                integer(body, "repeat_period_ms", 100, 10000, 2000)
                request = urllib.request.Request(
                    f"http://{host}:8080/cgi-bin/adf4159.cgi?mode=stream",
                    data=json.dumps({k: v for k, v in body.items() if k != "host"}).encode(),
                    headers={"Content-Type": "application/json"}, method="POST",
                )
                try:
                    response = urllib.request.urlopen(request, timeout=30)
                except urllib.error.HTTPError as exc:
                    try:
                        message = json.load(exc).get("error", str(exc))
                    except (ValueError, OSError):
                        message = str(exc)
                    raise BoardError(message) from exc
                except (urllib.error.URLError, TimeoutError) as exc:
                    raise BoardError(f"board stream service on port 8080 is unavailable: {exc}") from exc
                with response:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    try:
                        while chunk := response.read1(4096):
                            self.wfile.write(chunk)
                            self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        pass
            elif path == "/api/gate":
                action = body.get("action", "status")
                if action not in ("status", "trigger", "stop"):
                    raise BadRequest("action must be status, trigger or stop")
                timeout = integer(body, "timeout_ms", 1, 1000, 500)
                with self.server.operation_lock:
                    result = board_cgi(host, "gate", {"action": action, "timeout_ms": timeout})
                self.json_reply(200, result)
            elif path == "/api/tx2":
                action = body.get("action", "status")
                if action not in ("status", "affirm", "revoke"):
                    raise BadRequest("action must be status, affirm or revoke")
                if action == "affirm" and body.get("path_confirmed") is not True:
                    raise BadRequest("confirm the TX2A through 20 dB pad to RX2A path first")
                with self.server.operation_lock:
                    result = board_cgi(host, "tx2", {"action": action, "path_confirmed": body.get("path_confirmed") is True})
                self.json_reply(200, result)
            elif path == "/api/registers":
                words = raw_words(body)
                with self.server.operation_lock:
                    write_registers(host, words)
                    self.server.last_write[host] = {
                        "at_utc": datetime.now(timezone.utc).isoformat(),
                        "mode": "raw", "words": [f"0x{w:08X}" for w in words],
                    }
                self.json_reply(200, {"host": host, "written": [f"0x{w:08X}" for w in words]})
            else:
                expected_hz = integer(body, "expected_frequency_hz", 70_000_000, 6_000_000_000)
                offset_hz = integer(body, "offset_hz", 500_000, 5_000_000, 1_000_000)
                lo_hz = expected_hz - offset_hz
                if lo_hz < 70_000_000:
                    raise BadRequest("RX LO would be below 70 MHz; increase expected frequency")
                with self.server.operation_lock:
                    raw, sample_rate = capture_rx1(host, lo_hz)
                result = analyze_capture(raw, sample_rate, lo_hz, offset_hz)
                self.json_reply(200, {"host": host, "measurement": result})
        except (BadRequest, BoardError, ValueError) as exc:
            self.json_reply(400 if isinstance(exc, BadRequest) else 502, {"error": str(exc)})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1", help="HTTP bind address (default: localhost)")
    parser.add_argument("--port", type=int, default=8765, help="HTTP port (default: 8765)")
    args = parser.parse_args()
    server = App((args.bind, args.port))
    print(f"ADF4159 UI: http://{args.bind}:{server.server_port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
