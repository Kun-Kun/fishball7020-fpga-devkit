"""Find Mode S messages in complex baseband samples. numpy only, no radio.

How a message looks on the air. Mode S uses pulse-position modulation (PPM):
time is cut into 1 us bits, each bit into two 0.5 us halves ("chips"), and
the transmitter is on in exactly one of them - the first half for a 1, the
second for a 0. Before the data comes an 8 us preamble with four pulses, at
0, 1, 3.5 and 4.5 us, which nothing in the data can imitate:

    chip:  0 1 2 3 4 5 6 7 8 9 10..15 | 16 17 | 18 19 | ...
           # . # . . . . # . #  quiet  | bit 0 | bit 1 |

The receiver is zero-IF, so the carrier sits at 0 Hz and only the envelope
(the magnitude of each IQ sample) matters. At 4 MSPS a chip is exactly two
samples, which is why 4 MSPS is the default: a chip never has to be guessed
from a sample that straddles two of them.

The search, per block of samples:
  1. magnitude, then the energy of every chip-long window (a moving sum);
  2. a preamble score at every sample: the four pulse windows against the
     twelve windows that must be quiet - vectorised, so only the few hundred
     places that look like a preamble reach Python;
  3. at each of those, read 56 bits, find the downlink format and so the
     length, read the rest, and hand the bytes on. The checksum is judged in
     modes.py, not here.
Blocks overlap by one whole message, so a message across a block boundary is
found once, in the block where it starts.
"""

import numpy as np

CHIP_RATE = 2_000_000                  # chips per second: 0.5 us each
PULSE_CHIPS = (0, 2, 7, 9)
QUIET_CHIPS = (1, 3, 4, 5, 6, 8, 10, 11, 12, 13, 14, 15)
PREAMBLE_CHIPS = 16
LONG_BITS = 112
FULL_SCALE = 2048.0                    # the AD9361's 12-bit full scale, in int16


class Frame:
    __slots__ = ("msg", "sample", "rssi", "snr")

    def __init__(self, msg, sample, rssi, snr):
        self.msg = msg            # bytes, 7 or 14 of them
        self.sample = sample      # absolute sample index where the preamble starts
        self.rssi = rssi          # mean pulse level, dBFS
        self.snr = snr            # pulse level over the block's noise floor, dB

    def __repr__(self):
        return f"Frame({self.msg.hex()}, @{self.sample}, {self.rssi:.1f} dBFS)"


class Demodulator:
    """Feed it consecutive blocks of complex samples; it returns Frames.

    fs must be a whole multiple of 2 MHz (2, 4, 6, 8 ... MSPS); 4 MSPS is the
    tested rate. min_snr_db is how far the preamble pulses must stand above
    the noise floor; 8-10 dB keeps false preambles rare without losing
    aircraft that a 12-bit receiver can actually decode."""

    NOISE_SAMPLES = 1_000_000     # how far back the noise floor looks

    def __init__(self, fs=4e6, min_snr_db=9.0, ratio_db=6.0, noise=None):
        spc = fs / CHIP_RATE
        if spc < 1 or abs(spc - round(spc)) > 1e-9:
            raise ValueError(f"sample rate must be a multiple of 2 MHz, not {fs:g}")
        self.fs = fs
        self.s = int(round(spc))
        self.min_snr = 10 ** (min_snr_db / 20)
        self.ratio = 10 ** (ratio_db / 20)
        self.span = (PREAMBLE_CHIPS + 2 * LONG_BITS) * self.s   # one long message
        self._tail = np.zeros(0, np.complex64)
        self._pos = 0             # absolute index of the next new sample
        self._skip = 0            # absolute index the last message ran up to
        self.preambles = 0        # preambles whose bits were read, for the status line
        self._noise = noise
        self._fixed_noise = noise is not None     # tests: a floor that never moves

    def reset(self, position=0):
        self._tail = np.zeros(0, np.complex64)
        self._pos = position
        self._skip = position

    def feed(self, iq):
        """Process the next block. Returns the Frames that start in it."""
        start = self._pos - len(self._tail)
        buf = np.concatenate((self._tail, iq)) if len(self._tail) else iq
        self._pos += len(iq)
        frames, stop = self._search(buf, start)
        keep = max(len(buf) - stop, 0)
        self._tail = buf[len(buf) - keep:].copy() if keep else np.zeros(0, np.complex64)
        return frames

    def _search(self, buf, start):
        s = self.s
        n_valid = len(buf) - self.span       # last start that has room for a long message
        if n_valid <= 0:
            return [], 0
        mag = np.abs(buf).astype(np.float32)
        cs = np.concatenate(([0.0], np.cumsum(mag, dtype=np.float64)))
        chip = (cs[s:] - cs[:-s]).astype(np.float32)      # energy of [n, n+s)
        # The noise floor, smoothed over about a quarter of a second, so the
        # threshold does not depend on how the stream happened to be cut up.
        med = float(np.median(chip)) + 1e-6
        w = min(1.0, len(buf) / self.NOISE_SAMPLES)
        if self._noise is None:
            self._noise = med
        elif not self._fixed_noise:
            self._noise = (1 - w) * self._noise + w * med
        noise = self._noise

        idx = np.arange(n_valid)
        hi = sum(chip[idx + c * s] for c in PULSE_CHIPS) / len(PULSE_CHIPS)
        lo = sum(chip[idx + c * s] for c in QUIET_CHIPS) / len(QUIET_CHIPS)
        # Starts are searched only where the alignment window below fits whole;
        # the rest is searched again in the next block, with more samples.
        n_search = n_valid - PREAMBLE_CHIPS * s
        if n_search <= 0:
            return [], 0
        ok = (hi[:n_search] > self.ratio * lo[:n_search]) \
            & (hi[:n_search] > self.min_snr * noise)
        cand = np.flatnonzero(ok)

        frames = []
        next_free = self._skip - start
        for n in cand:
            if n < next_free:
                continue
            # The first hit is often not the preamble but a shifted copy of it
            # lining two of its pulses up with two real ones, so take the best
            # alignment over the next preamble's length, scored by contrast.
            win = np.arange(n, n + PREAMBLE_CHIPS * s)
            score = hi[win] / (lo[win] + noise)
            n = int(win[np.argmax(score)])
            if not (hi[n] > self.ratio * lo[n] and hi[n] > self.min_snr * noise):
                continue
            self.preambles += 1
            d = n + PREAMBLE_CHIPS * s
            early = chip[d:d + 2 * LONG_BITS * s:2 * s]
            late = chip[d + s:d + (2 * LONG_BITS + 1) * s:2 * s]
            bits = (early > late).astype(np.uint8)
            df = int(bits[0]) << 4 | int(bits[1]) << 3 | int(bits[2]) << 2 \
                | int(bits[3]) << 1 | int(bits[4])
            nbits = LONG_BITS if df >= 16 else 56
            msg = np.packbits(bits[:nbits]).tobytes()
            level = float(hi[n]) / s
            rssi = 20 * np.log10(max(level, 1e-9) / FULL_SCALE)
            snr = 20 * np.log10(float(hi[n]) / noise)
            frames.append(Frame(msg, start + n, rssi, snr))
            # Do not look for another preamble inside this message; if its
            # checksum fails, modes.py drops it and that costs one message.
            next_free = n + (PREAMBLE_CHIPS + 2 * nbits) * s
            self._skip = start + next_free
        return frames, n_search


# ---- a transmitter, for tests ----------------------------------------------

def modulate(messages, fs=4e6, amplitude=1000.0, gap_us=200.0, noise=20.0,
             seed=1, offset_samples=0, phase_drift=0.0):
    """Complex samples carrying `messages` (bytes), one every gap_us.

    Returns (iq, starts): starts are the sample index of each preamble. The
    carrier gets a random phase and an optional frequency offset (radians per
    sample), because a real receiver sees both and a demodulator that only
    works at 0 Hz is broken."""
    s = int(round(fs / CHIP_RATE))
    rng = np.random.default_rng(seed)
    gap = int(gap_us * 1e-6 * fs)
    total = offset_samples + gap * (len(messages) + 1)
    env = np.zeros(total, np.float32)
    starts = []
    for k, msg in enumerate(messages):
        n0 = offset_samples + gap * k + gap // 2
        starts.append(n0)
        chips = np.zeros(PREAMBLE_CHIPS + 2 * 8 * len(msg), np.float32)
        chips[list(PULSE_CHIPS)] = 1
        bits = np.unpackbits(np.frombuffer(msg, np.uint8))
        chips[PREAMBLE_CHIPS + 2 * np.arange(len(bits)) + (1 - bits)] = 1
        env[n0:n0 + len(chips) * s] = np.repeat(chips, s)
    phase = rng.uniform(0, 2 * np.pi) + phase_drift * np.arange(total)
    iq = amplitude * env * np.exp(1j * phase)
    iq += noise * (rng.standard_normal(total) + 1j * rng.standard_normal(total)) / np.sqrt(2)
    return iq.astype(np.complex64), starts
