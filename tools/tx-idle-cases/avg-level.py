#!/usr/bin/env python3
"""Averaged level at an absolute frequency over time windows of a cs8 capture.

    ./avg-level.py <file.cs8> <fs> <centre_hz> <target_hz> label:t0:t1 [label:t0:t1 ...]

USE THIS, NOT cs8-level.py, for anything at or near the noise floor. cs8-level.py
reports the maximum of a SINGLE FFT, and the maximum of one 2048-bin FFT of pure
noise sits 8-16 dB above the median - it reads exactly like a carrier. This one
averages every FFT in the window, which is what makes a null mean anything.

WHAT THE COLUMNS ARE, because a dBFS number with no bandwidth is not a level:
  target  the maximum within +-25 kHz of the target frequency, per bin, averaged
          over nFFT periodograms.

          RESOLUTION BANDWIDTH. fs/4096 is the BIN SPACING - 977 Hz at 4 MSPS - and
          that is NOT the noise bandwidth. The window is Hann, whose equivalent noise
          bandwidth is 1.5004 bins, so the real RBW is 1.5*fs/N = **1465 Hz** at
          4 MSPS. Two consequences, both of which reached the repo's deliverable
          before round 8 caught them:
            - a noise-floor reading here is 10*log10(1.5) = 1.76 dB below the true
              power in one noise bandwidth, so a dBm constant calibrated from a TONE
              must not be applied to a floor reading without that correction;
            - the number of independent noise bandwidths in the span is fs/ENBW, not
              nfft: 2730 in 4 MHz (+34.36 dB), not 4096 (+36.12 dB).
          Also note the peak-bin estimate carries up to 1.42 dB of Hann scalloping
          loss, so `target` is not an absolute tone power.
  floor   the MEDIAN over every bin more than 200 kHz from DC and 300 kHz from
          the target. Not a noise figure - it is this receiver's floor at this
          gain, and it is the witness that the receiver gain did not move between
          captures. Publish it with every result.
  excess  target - floor. NOT signal power: at low excess the target bin holds
          signal PLUS noise. Floor-subtracted power is
              10*log10(10**(excess/10) - 1)
          which at +8.21 dB is 0.71 dB below the reading, and at +0.16 dB is
          -14.3 dB, i.e. below the floor. Quote the subtracted figure.
  drop%   the fraction of blocks discarded for clipping, to ONE decimal - so up to
          ~0.05 % (21 blocks of 43,000) prints as "0.0%". Read it as "few", not none. Ambient 2.4 GHz Wi-Fi
          arrives in bursts; one clipped block smears energy across every bin.
          The threshold is on max(|I|,|Q|) >= 120/127, which rejects saturation but is NOT a
          linearity guard - 119/127 is about -0.6 dBFS, already in compression.
          A discarded block is also how a genuine transient from the board would
          be thrown away, so a non-zero figure needs looking at, not rounding.


Averaging matters. The maximum of ONE FFT of pure noise sits 8-16 dB above the
median and reads exactly like a signal - that artefact is what made an earlier
pass here report a "+15 dB bump" at the TX LO on a muted board. Every number
below is a mean over every FFT in its window.

Accumulated in CHUNKS: a 60 s window at 4 MSPS is 240 M samples, and holding
that as one complex array is ~2 GB, which thrashes a 16 GB machine.
"""
import sys
import numpy as np

path, fs, fc, ftarget = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
N, CH = 4096, 4096 * 512                      # FFT length, samples per chunk

mm = np.memmap(path, dtype=np.int8, mode="r")
total = mm.shape[0] // 2
f = np.fft.fftshift(np.fft.fftfreq(N, 1 / fs))
off = ftarget - fc
band = np.abs(f - off) < 25e3                 # the target, +-25 kHz
ctl = (np.abs(f) > 200e3) & (np.abs(f - off) > 300e3)   # elsewhere, clear of DC
w = np.hanning(N).astype(np.float32)

print(f"  target {ftarget/1e6:.3f} MHz = offset {off/1e3:+.0f} kHz from centre")
print(f"  {'window':<28}{'t0':>7}{'t1':>7}{'target':>9}{'floor':>9}{'excess':>8}{'nFFT':>9}{'drop%':>7}")
for spec in sys.argv[5:]:
    label, t0, t1 = spec.split(":")
    a = max(0, int(float(t0) * fs))
    b = min(total, int(float(t1) * fs))
    acc = np.zeros(N)
    nf = 0
    mx = 0
    dropped = 0
    while a + N <= b:
        n = min(CH, ((b - a) // N) * N)
        blk = np.asarray(mm[2 * a:2 * (a + n)], dtype=np.int8)
        mx = max(mx, int(np.abs(blk).max()))
        iq = (blk[0::2].astype(np.float32) + 1j * blk[1::2].astype(np.float32)) / 127.0
        iq = iq.reshape(-1, N)
        # Ambient 2.4 GHz Wi-Fi arrives as bursts that clip the ADC. One clipped block
        # smears energy across every bin and would read as a wideband emission. Drop
        # the blocks it touches rather than the whole capture, and count them, because
        # "how much did I throw away" is part of the result.
        peak = np.maximum(np.abs(iq.real), np.abs(iq.imag)).max(axis=1)
        good = peak < (120.0 / 127.0)
        dropped += int((~good).sum())
        iq = iq[good]
        if iq.shape[0] == 0:
            a += n
            del blk
            continue
        acc += (np.abs(np.fft.fftshift(np.fft.fft(iq * w, axis=1), axes=1)) ** 2).sum(axis=0)
        nf += iq.shape[0]
        a += n
        del blk, iq
    if nf == 0:
        print(f"  {label:<28} window empty")
        continue
    db = 10 * np.log10(acc / nf / (N ** 2) + 1e-30)
    tgt, flr = db[band].max(), np.median(db[ctl])
    pct = 100.0 * dropped / max(1, dropped + nf)
    print(f"  {label:<28}{float(t0):7.1f}{float(t1):7.1f}{tgt:9.2f}{flr:9.2f}"
          f"{tgt-flr:+8.2f}{nf:9d}{pct:6.1f}%")
