"""The receive loop: source -> demodulator -> aircraft table, in a thread.

Shared by the window and the text mode. The reader thread never waits on the
display: blocks go through a bounded queue to the decoding thread, and when
decoding falls behind a block is dropped and counted, rather than letting
iio_readdev's pipe fill up and the board drop samples nobody counts.
"""

import collections
import queue
import threading
import time

from demod import Demodulator
import modes


class Receiver:
    def __init__(self, source, ref=None, min_snr_db=9.0, recorder=None):
        self.source = source
        self.tracker = modes.Tracker(ref=ref)
        self.demod = None
        self.min_snr_db = min_snr_db
        self.recorder = recorder
        self.record_error = None
        self.log = queue.Queue()          # (time, status, rssi, icao, fields)
        self.lock = threading.Lock()      # guards tracker for snapshot()
        self.stop = threading.Event()
        self.error = None
        self.done = threading.Event()
        self.counters = collections.Counter()
        self._blocks = queue.Queue(maxsize=16)
        self._rate_t = time.monotonic()
        self._rate_n = 0
        self.samples_per_s = 0.0
        self._last_block = time.monotonic()

    def start(self, rb=None):
        """rb: the source's configure() result, if it was already called."""
        rb = rb or self.source.configure()
        self.demod = Demodulator(rb["sample_rate"], min_snr_db=self.min_snr_db)
        threading.Thread(target=self._read, name="adsb-read", daemon=True).start()
        threading.Thread(target=self._decode, name="adsb-decode", daemon=True).start()
        return rb

    def close(self):
        self.stop.set()
        self.source.close()
        self.done.wait(5)
        if self.recorder:
            try:
                self.recorder.close()
            except OSError:
                pass

    def _read(self):
        pos = 0
        try:
            for iq in self.source.blocks(self.stop):
                try:
                    self._blocks.put_nowait((pos, iq))
                except queue.Full:
                    self.counters["blocks_dropped"] += 1
                pos += len(iq)
        except Exception as e:                      # noqa: BLE001 - shown to the user
            self.error = str(e)
        finally:
            self._blocks.put(None)

    def _decode(self):
        expected = 0
        try:
            while True:
                item = self._blocks.get()
                if item is None:
                    break
                pos, iq = item
                if pos != expected:                 # a block was dropped: do not
                    self.demod.reset(pos)           # stitch across the gap
                expected = pos + len(iq)
                if self.recorder:
                    try:
                        self.recorder.write(iq)
                    except OSError as e:            # a full disk ends the recording,
                        self.record_error = str(e)  # not the reception
                        rec, self.recorder = self.recorder, None
                        try:
                            rec.close()
                        except OSError:
                            pass
                self._count(len(iq))
                frames = self.demod.feed(iq)
                now = time.time()
                with self.lock:
                    for f in frames:
                        # when it was on the air: the block ended at `now`
                        t = now - (expected - f.sample) / self.demod.fs
                        r = self.tracker.feed(f.msg, now=now, rssi=f.rssi)
                        if r is not None:
                            status, icao, d = r
                            self.log.put((t, status, f.rssi, icao, d))
                    self.tracker.prune(now)
        except Exception as e:                      # noqa: BLE001
            self.error = self.error or f"decoder: {e}"
            self.stop.set()
        finally:
            self.done.set()

    def _count(self, n):
        self._rate_n += n
        t = self._last_block = time.monotonic()
        if t - self._rate_t >= 1.0:
            self.samples_per_s = self._rate_n / (t - self._rate_t)
            self._rate_t, self._rate_n = t, 0

    def snapshot(self):
        """A copy of the aircraft table and the counters, safe to read anywhere."""
        with self.lock:
            rows = [{k: getattr(a, k) for k in (
                "icao", "callsign", "squawk", "altitude", "speed", "speed_kind",
                "track", "vrate", "lat", "lon", "messages", "first_seen",
                "last_seen", "rssi")} for a in self.tracker.aircraft.values()]
            stats = dict(self.tracker.stats)
        stats.update(self.counters)
        stats["preambles"] = self.demod.preambles if self.demod else 0
        stats["samples_per_s"] = self.samples_per_s
        stats["rate"] = self.demod.fs if self.demod else 0
        stats["record_error"] = self.record_error
        stats["replay"] = hasattr(self.source, "path")     # a FileSource
        # iio_readdev can stop delivering without exiting. Then nothing updates
        # and frozen numbers look exactly like an empty sky, so say it.
        quiet = time.monotonic() - self._last_block
        if not stats["replay"] and quiet > 3 and not self.done.is_set():
            stats["samples_per_s"] = 0.0
            stats["stalled_s"] = quiet
        return rows, stats

    def drain_log(self, limit=2000):
        out = []
        while len(out) < limit:
            try:
                out.append(self.log.get_nowait())
            except queue.Empty:
                break
        return out


def log_line(entry):
    t, status, rssi, icao, d = entry
    stamp = time.strftime("%H:%M:%S", time.localtime(t)) + f".{int(t * 1000) % 1000:03d}"
    mark = {"ok": "CRC ok", "fixed": "fixed1", "addr": "AP ok "}[status]
    hexs = d["hex"]
    return (f"{stamp}  {rssi:6.1f} dBFS  {mark}  {icao:06X}  {hexs:<28}  "
            f"{modes.summary(d)}" + (f"  {d['lat']:.4f},{d['lon']:.4f}" if "lat" in d else ""))
