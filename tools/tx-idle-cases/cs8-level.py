#!/usr/bin/env python3
"""Levels from a HackRF .cs8 capture: the analyser behind IDLE-CASES.md's ladder.

    ./cs8-level.py FILE FS [--at OFFSET_HZ] [--slice SECONDS] [--from T0 --to T1]

Prints, for the whole file or per time slice: the peak in dBFS, the median noise floor,
and **max|sample|** with a clipping flag. That last column is not decoration - the
power-on burst saturated the receiver, and a saturated reading is a ceiling rather than
a level: feed this arithmetic a tone at amplitude x2 and x100 and both report the same
dBFS. Any level quoted without it may be a ceiling.

This was missing from the repo, which made the calibration ladder in IDLE-CASES.md
unreproducible even though the capture scripts beside it were committed.
"""
from __future__ import annotations

import argparse
import numpy as np


def analyse(iq: np.ndarray, fs: float, nfft: int, target: float | None):
    iq = iq - iq.mean()                       # the receiver's DC offset is not signal
    n = len(iq) // nfft
    if n == 0:
        return None
    a = iq[:n * nfft].reshape(n, nfft)
    P = 10 * np.log10(np.abs(np.fft.fftshift(np.fft.fft(a * np.hanning(nfft), axis=1),
                                             axes=1)) ** 2 / (nfft ** 2) + 1e-30)
    f = np.fft.fftshift(np.fft.fftfreq(nfft, 1 / fs))
    away = np.abs(f) > 80e3                   # keep the DC leak out of the floor
    floor = float(np.median(P[:, away]))
    j = int(np.unravel_index(np.argmax(np.where(away, P, -1e9)), P.shape)[1])
    out = {"peak": float(P[:, away].max()), "peak_hz": float(f[j]), "floor": floor}
    if target is not None:
        band = np.abs(f - target) < 40e3
        out["at"] = float(P[:, band].max()) if band.any() else float("nan")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("fs", type=float)
    ap.add_argument("--at", type=float, default=None, help="also report this offset, Hz")
    ap.add_argument("--slice", type=float, default=None, help="seconds per slice")
    ap.add_argument("--from", dest="t0", type=float, default=None)
    ap.add_argument("--to", dest="t1", type=float, default=None)
    ap.add_argument("--nfft", type=int, default=2048)
    a = ap.parse_args()

    raw = np.memmap(a.file, dtype=np.int8, mode="r")
    total = raw.shape[0] // 2
    s0 = int((a.t0 or 0) * a.fs)
    s1 = int(a.t1 * a.fs) if a.t1 else total
    step = int(a.slice * a.fs) if a.slice else (s1 - s0)

    hdr = f"  {'t(s)':>8}  {'peak':>8}  {'floor':>8}  {'delta':>7}  {'max|s|':>6}  clip"
    if a.at is not None:
        hdr += f"  {'at %+.0f kHz' % (a.at / 1e3):>14}"
    print(hdr)
    for k in range(s0, s1 - 1, step):
        end = min(k + step, s1)
        blk = np.asarray(raw[2 * k:2 * end], dtype=np.int8)
        mx = max(int(np.abs(blk[0::2]).max()), int(np.abs(blk[1::2]).max()))
        iq = (blk[0::2].astype(np.float32) + 1j * blk[1::2].astype(np.float32)) / 127.0
        r = analyse(iq, a.fs, a.nfft, a.at)
        if r is None:
            continue
        line = (f"  {k / a.fs:8.3f}  {r['peak']:+8.1f}  {r['floor']:+8.1f}  "
                f"{r['peak'] - r['floor']:+7.1f}  {mx:6d}  "
                f"{'** CLIPPING - this is a CEILING, not a level **' if mx >= 127 else ''}")
        if a.at is not None:
            line += f"  {r['at']:+14.1f}"
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
