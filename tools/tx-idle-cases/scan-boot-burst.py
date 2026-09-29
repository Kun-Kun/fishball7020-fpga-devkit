#!/usr/bin/env python3
"""Scan a whole capture for NARROWBAND events at the TX LO.

Per 2048-sample FFT, compare the TX-LO band against two control bands. Report
every FFT where TX exceeds both controls by the threshold - so a 10 ms burst in a
300 s file is found without knowing where to look, and a broadband click (all
bands up together) is rejected rather than reported.
"""
import sys, numpy as np
path = sys.argv[1]; fs = 4e6; thresh = float(sys.argv[2]) if len(sys.argv) > 2 else 15.0
nfft = 2048
mm = np.memmap(path, dtype=np.int8, mode="r")
nsamp = mm.shape[0] // 2
nblk = nsamp // nfft
f = np.fft.fftshift(np.fft.fftfreq(nfft, 1/fs))
tx = np.abs(f - 1.5e6) < 40e3
c1 = np.abs(f + 1.5e6) < 40e3
c2 = np.abs(f - 0.5e6) < 40e3
w = np.hanning(nfft).astype(np.float32)
CHUNK = 4096          # FFTs per pass
events = []
for base in range(0, nblk, CHUNK):
    m = min(CHUNK, nblk - base)
    blk = np.asarray(mm[2*base*nfft : 2*(base+m)*nfft], dtype=np.int8)
    iq = (blk[0::2].astype(np.float32) + 1j*blk[1::2].astype(np.float32)) / 127.0
    iq = iq.reshape(m, nfft)
    iq = iq - iq.mean(axis=1, keepdims=True)
    F = np.fft.fftshift(np.fft.fft(iq * w, axis=1), axes=1)
    P = 10*np.log10(np.abs(F)**2 / (nfft**2) + 1e-30)
    a = P[:, tx].max(axis=1); b = np.maximum(P[:, c1].max(axis=1), P[:, c2].max(axis=1))
    hit = np.where(a - b > thresh)[0]
    for h in hit:
        events.append(((base+h)*nfft/fs, float(a[h]), float(b[h])))
print(f"  scanned {nsamp/fs:.1f} s in {nblk} FFTs of {nfft} ({nfft/fs*1000:.2f} ms each)")
print(f"  narrowband events, TX band more than {thresh:.0f} dB above BOTH controls: {len(events)}")
if events:
    # group into bursts
    groups = []
    for t, a, b in events:
        if groups and t - groups[-1][-1][0] < 0.100: groups[-1].append((t, a, b))
        else: groups.append([(t, a, b)])
    print(f"  grouped into {len(groups)} burst(s):")
    for g in groups:
        t0 = g[0][0]; t1 = g[-1][0] + nfft/fs
        pk = max(x[1] for x in g); ctl = max(x[2] for x in g)
        print(f"    t = {t0:7.3f} .. {t1:7.3f} s  ({(t1-t0)*1000:6.1f} ms)  peak {pk:+7.1f} dBFS  "
              f"best control {ctl:+7.1f}  separation {pk-ctl:+5.1f} dB")
