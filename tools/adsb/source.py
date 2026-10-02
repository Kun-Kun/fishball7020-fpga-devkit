"""Where the samples come from: the board's RX1 or RX2, or a recording.

The board side needs only libiio's command-line tools (iio_attr, iio_readdev),
the same as tools/sigmf-capture.py; no Python bindings. Receive only: nothing
here opens, writes or even reads a transmit device.
"""

import json
import pathlib
import subprocess
import sys
import threading
import time

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from board_addr import uri as board_uri                # noqa: E402

PHY = "ad9361-phy"
RX = "cf-ad9361-lpc"
# Two numbering schemes (tools/sigmf-capture.py has the hardware proof):
#   ad9361-phy     voltage0 = RX1, voltage1 = RX2      (gain; rate and bandwidth
#                                                      are shared, set on voltage0)
#   cf-ad9361-lpc  voltage0/1 = RX1 I/Q, voltage2/3 = RX2 I/Q   (the samples)
def phy_ch(rx):
    return f"voltage{rx - 1}"


def stream_iq(rx):
    return (f"voltage{2 * (rx - 1)}", f"voltage{2 * (rx - 1) + 1}")


class BoardError(Exception):
    pass


def iio_attr(uri, *args):
    """One iio_attr call; returns its first output token. Raises on failure:
    a refused write that is ignored looks exactly like an applied one."""
    try:
        out = subprocess.run(["iio_attr", "-u", uri, *args],
                             capture_output=True, text=True, timeout=20)
    except FileNotFoundError:
        raise BoardError("iio_attr not found: install libiio's tools "
                         "(Arch: libiio, Debian/Ubuntu: libiio-utils)") from None
    except subprocess.TimeoutExpired:
        raise BoardError(f"iio_attr {' '.join(args)}: no answer in 20 s") from None
    if out.returncode != 0:
        msg = (out.stderr or out.stdout).strip().splitlines()
        raise BoardError(f"iio_attr {' '.join(args)}: {msg[-1] if msg else 'failed'}"
                         f" (exit {out.returncode})")
    lines = out.stdout.strip().splitlines()
    return lines[-1].split()[0] if lines and lines[-1].split() else ""


class BoardSource:
    """RX1 or RX2 (`channel`) at 1090 MHz, streamed with iio_readdev.

    gain is a number in dB (manual) or "agc" (the AD9361's slow_attack loop).
    Manual is the default: ADS-B arrives in 120 us bursts with silence between,
    and an AGC that hunts between bursts moves the noise floor under the
    detector."""

    def __init__(self, uri=None, freq=1_090_000_000, rate=4_000_000,
                 bandwidth=None, gain=25, block=1 << 20, channel=1):
        if channel not in (1, 2):
            raise BoardError(f"channel is 1 or 2, not {channel}")
        self.channel = channel
        self.uri = uri or board_uri()
        self.freq, self.rate, self.gain, self.block = int(freq), int(rate), gain, block
        self.bandwidth = int(bandwidth or rate)
        self.readback = {}
        self._proc = None
        self._err = b""

    def _set(self, *args):
        iio_attr(self.uri, *args)

    def configure(self):
        """Write the receive settings, then read every one back: a value written
        is an intention, the value read back is what the radio does."""
        u = self.uri
        self._set("-o", "-c", PHY, "altvoltage0", "frequency", str(self.freq))
        self._set("-i", "-c", PHY, "voltage0", "sampling_frequency", str(self.rate))
        self._set("-i", "-c", PHY, "voltage0", "rf_bandwidth", str(self.bandwidth))
        # The FPGA decimator (and the optional channel filter behind it) is
        # engaged by a lower rate on the capture device. Match the converter
        # rate so samples arrive undecimated: a narrow filter left on from an
        # FM session would smear 0.5 us pulses into nothing.
        try:
            self._set("-i", "-c", RX, "voltage0", "sampling_frequency", str(self.rate))
        except BoardError:
            pass                                   # judged by the read-back below
        self.set_gain(self.gain)
        rb = {
            "uri": u,
            "channel": self.channel,
            "frequency": int(iio_attr(u, "-o", "-c", PHY, "altvoltage0", "frequency")),
            "sample_rate": int(iio_attr(u, "-i", "-c", PHY, "voltage0", "sampling_frequency")),
            "fabric_rate": int(iio_attr(u, "-i", "-c", RX, "voltage0", "sampling_frequency")),
            "rf_bandwidth": int(iio_attr(u, "-i", "-c", PHY, "voltage0", "rf_bandwidth")),
        }
        self.readback.update(rb)
        if abs(rb["frequency"] - self.freq) > 1000:
            raise BoardError(f"RX LO reads {rb['frequency']} Hz, not {self.freq}")
        if rb["sample_rate"] != self.rate:
            raise BoardError(f"converter rate reads {rb['sample_rate']}, not {self.rate}; "
                             "the demodulator needs a multiple of 2 MSPS")
        if rb["fabric_rate"] != rb["sample_rate"]:
            raise BoardError(
                f"the FPGA decimator is engaged ({RX} delivers {rb['fabric_rate']} S/s "
                f"from {rb['sample_rate']}) and refused to be bypassed. Set "
                f"`iio_attr -i -c {RX} voltage0 sampling_frequency {rb['sample_rate']}`.")
        return self.readback

    def set_gain(self, gain):
        """Live: a gain change needs no buffer restart."""
        u, ch = self.uri, phy_ch(self.channel)
        if gain == "agc":
            self._set("-i", "-c", PHY, ch, "gain_control_mode", "slow_attack")
        else:
            # manual first, or the hardwaregain write is refused
            self._set("-i", "-c", PHY, ch, "gain_control_mode", "manual")
            self._set("-i", "-c", PHY, ch, "hardwaregain", str(float(gain)))
        self.gain = gain
        self.readback["gain_mode"] = iio_attr(u, "-i", "-c", PHY, ch, "gain_control_mode")
        self.readback["gain_db"] = self.read_gain()
        return self.readback["gain_db"]

    def read_gain(self):
        return float(iio_attr(self.uri, "-i", "-c", PHY, phy_ch(self.channel), "hardwaregain"))

    def blocks(self, stop):
        """Yield complex64 blocks until stop is set. Raises BoardError when the
        stream ends on its own."""
        cmd = ["iio_readdev", "-u", self.uri, "-b", str(self.block), RX,
               *stream_iq(self.channel)]
        try:
            self._proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, bufsize=0)
        except FileNotFoundError:
            raise BoardError("iio_readdev not found: install libiio's tools") from None
        threading.Thread(target=self._drain_stderr, daemon=True).start()
        nbytes = self.block * 4
        f = self._proc.stdout
        try:
            while not stop.is_set():
                raw = _read_exact(f, nbytes)
                if raw is None:
                    break
                s = np.frombuffer(raw, np.int16).astype(np.float32)
                yield (s[0::2] + 1j * s[1::2]).astype(np.complex64)
        finally:
            self.close()
        if not stop.is_set():
            err = self._err.decode(errors="replace").strip()
            if "busy" in err.lower() or "EBUSY" in err:
                raise BoardError("something else holds the receiver (SDR++, a capture, "
                                 "or the hardware CI on this board): " + err)
            raise BoardError("the sample stream stopped" + (f": {err}" if err else ""))

    def _drain_stderr(self):
        p = self._proc
        if p and p.stderr:
            for line in p.stderr:
                self._err += line

    def close(self):
        p, self._proc = self._proc, None
        if p and p.poll() is None:
            p.terminate()
            try:
                p.wait(3)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()


def _read_exact(f, n):
    chunks, got = [], 0
    while got < n:
        b = f.read(n - got)
        if not b:
            return None
        chunks.append(b)
        got += len(b)
    return b"".join(chunks)


class FileSource:
    """A recording: SigMF (.sigmf-data/.sigmf-meta, ci16_le), whose own rate is
    used, or raw interleaved int16 I/Q at `rate`. Played in real time unless
    fast."""

    def __init__(self, path, rate=None, fast=False, loop=False, block=1 << 18):
        p = pathlib.Path(path)
        if p.suffix in (".sigmf-meta", ".sigmf-data", ".sigmf"):
            p = p.with_suffix(".sigmf-data")
            meta = json.loads(p.with_suffix(".sigmf-meta").read_text())
            g = meta["global"]
            if g.get("core:datatype") != "ci16_le":
                raise BoardError(f"{p.name}: {g.get('core:datatype')} - only ci16_le is read")
            if g.get("core:num_channels", 1) != 1:
                raise BoardError(f"{p.name}: {g['core:num_channels']} channels interleaved;"
                                 " record one channel (or --split)")
            rate = g["core:sample_rate"]           # the recording knows best
            caps = meta.get("captures") or [{}]
            freq = caps[0].get("core:frequency")
            if freq and abs(freq - 1_090_000_000) > 1_000_000:
                print(f"warning: {p.name} was recorded at {freq / 1e6:.3f} MHz, "
                      "not 1090", file=sys.stderr)
        if not rate:
            raise BoardError(f"{p.name}: give the sample rate (--rate) for a raw file")
        self.path, self.rate, self.fast, self.loop, self.block = p, int(rate), fast, loop, block
        self.readback = {"uri": f"file:{p.name}", "sample_rate": self.rate,
                         "frequency": 1_090_000_000, "gain_db": None, "gain_mode": "recording"}

    def configure(self):
        return self.readback

    def set_gain(self, gain):
        return None

    def blocks(self, stop):
        t0, sent = time.monotonic(), 0
        while not stop.is_set():
            with open(self.path, "rb") as f:
                while not stop.is_set():
                    raw = f.read(self.block * 4)
                    if len(raw) < 4:
                        break
                    s = np.frombuffer(raw[:len(raw) // 4 * 4], np.int16).astype(np.float32)
                    iq = (s[0::2] + 1j * s[1::2]).astype(np.complex64)
                    if not self.fast:
                        ahead = (sent + len(iq)) / self.rate - (time.monotonic() - t0)
                        if ahead > 0:
                            stop.wait(ahead)
                    sent += len(iq)
                    yield iq
            if not self.loop:
                return

    def close(self):
        pass


class Recorder:
    """Write what the source delivers as SigMF, so a session can be replayed."""

    def __init__(self, path, readback):
        base = str(path)
        for suffix in (".sigmf-data", ".sigmf-meta"):
            if base.endswith(suffix):
                base = base[:-len(suffix)]
        self.data = open(base + ".sigmf-data", "wb")
        meta = {
            "global": {"core:datatype": "ci16_le", "core:version": "1.0.0",
                       "core:sample_rate": readback["sample_rate"],
                       "core:num_channels": 1,
                       "core:description": f"ADS-B, RX{readback.get('channel', 1)}, recorded by tools/adsb",
                       "core:recorder": "fishball7020 devkit adsb",
                       "fishball:full_scale": 2047,
                       "fishball:gain_db": readback.get("gain_db"),
                       "fishball:gain_mode": readback.get("gain_mode")},
            "captures": [{"core:sample_start": 0, "core:frequency": readback["frequency"],
                          "core:datetime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}],
            "annotations": [],
        }
        pathlib.Path(base + ".sigmf-meta").write_text(json.dumps(meta, indent=2) + "\n")
        self.path = base + ".sigmf-data"

    def write(self, iq):
        out = np.empty(2 * len(iq), np.int16)
        out[0::2] = np.round(iq.real)
        out[1::2] = np.round(iq.imag)
        self.data.write(out.tobytes())

    def close(self):
        self.data.close()

