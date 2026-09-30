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
# try/finally, because this opens a CYCLIC buffer. A cyclic transmit outlives the
# process that started it - that is measured, in IDLE-CASES.md path 6 - so an
# exception, a Ctrl-C during the sleep, a SIGHUP when the ssh session carrying the
# ladder loop drops, or a BrokenPipeError on the print below would all leave the
# carrier on the air at the commanded attenuation until the 60 s backstop, and
# forever on a kernel whose backstop is at its 0 default. Every other caller of
# Board.transmit() in this repo has this; tone.py was the one that did not, and it
# is the one that keys the published calibration ladder.
rc = 0
try:
    got = b.transmit(iq, atten, pair=pair, cyclic=True, scale=0.9)
    print(f"  transmitting on TX{pair+1}A: atten read back {got} dB, "
          f"tone at +{k*3.072e6/n/1e3:.1f} kHz "
          f"-> {(2400e6 + k*3.072e6/n)/1e6:.3f} MHz")
    import time; time.sleep(secs)
finally:
    try:
        st = b.stop()
        print("  stop():", st)
        # stop() reports whether it could PROVE both ports quiet. Acting on it is the
        # point of the return value: exiting 0 after an unproven mute is how a harness
        # records a live port as a clean run.
        if not st.get("muted", False):
            print("*** stop() COULD NOT PROVE BOTH CHANNELS MUTED - TREAT THEM AS "
                  "LIVE ***", file=sys.stderr)
            rc = 1
    except Exception as exc:                                  # noqa: BLE001
        print(f"*** stop() FAILED ({exc}) - TREAT THE PORTS AS LIVE ***", file=sys.stderr)
        rc = 1
    try: b.close()
    except Exception: pass
sys.exit(rc)
