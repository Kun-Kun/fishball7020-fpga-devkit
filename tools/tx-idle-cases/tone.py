#!/usr/bin/env python3
"""Transmit a cyclic tone on a named channel at a given attenuation, through the gate.

    ./tone.py <atten_db> [seconds] <0|1>     0 = TX1A, 1 = TX2A

The channel is REQUIRED and has no default. It used to default to 0, which made this
the one transmitting script in the directory that picked a port for you - the same
class of defect as a gate that defaults to affirmed, in the script that keys a raised
carrier for the calibration ladder.
"""
import sys, pathlib, numpy as np
sys.path.insert(0, "tools/modulation-gallery"); sys.path.insert(0, "tools")
import board as B
if len(sys.argv) < 4 or sys.argv[3] not in ("0", "1"):
    sys.exit("usage: tone.py <atten_db> <seconds> <0|1>   (0 = TX1A, 1 = TX2A)\n"
             "the channel is required - name the port you are about to key")
atten = float(sys.argv[1]); secs = float(sys.argv[2])
pair  = int(sys.argv[3])                                  # 0 = TX1A, 1 = TX2A
b = B.Board("192.168.2.1")
cfg = b.configure_tx(2400e6, 3.072e6)
n = 8192
k = 533                                   # bin -> +200 kHz at 3.072 MSPS
iq = np.exp(2j*np.pi*k*np.arange(n)/n)
got = b.transmit(iq, atten, pair=pair, cyclic=True, scale=0.9)
print(f"  transmitting on TX{pair+1}A: atten read back {got} dB, tone at +{k*3.072e6/n/1e3:.1f} kHz "
      f"-> {(2400e6 + k*3.072e6/n)/1e6:.3f} MHz")
import time; time.sleep(secs)
print("  stop():", b.stop()); b.close()
