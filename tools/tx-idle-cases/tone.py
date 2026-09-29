#!/usr/bin/env python3
"""Transmit a cyclic tone on TX1 at a given attenuation, through the gate."""
import sys, pathlib, numpy as np
sys.path.insert(0, "tools/modulation-gallery"); sys.path.insert(0, "tools")
import board as B
atten = float(sys.argv[1]); secs = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
b = B.Board("192.168.2.1")
cfg = b.configure_tx(2400e6, 3.072e6)
n = 8192
k = 533                                   # bin -> +200 kHz at 3.072 MSPS
iq = np.exp(2j*np.pi*k*np.arange(n)/n)
got = b.transmit(iq, atten, pair=0, cyclic=True, scale=0.9)
print(f"  transmitting: atten read back {got} dB, tone at +{k*3.072e6/n/1e3:.1f} kHz "
      f"-> {(2400e6 + k*3.072e6/n)/1e6:.3f} MHz")
import time; time.sleep(secs)
print("  stop():", b.stop()); b.close()
