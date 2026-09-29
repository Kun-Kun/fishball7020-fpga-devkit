#!/usr/bin/env python3
"""Measure the PREDICTED alias bin directly, against an in-band reference."""
import sys, numpy as np
sys.path.insert(0, "tools/selftest")
# THE GATE IS NOT OPTIONAL HERE. This keys BOTH transmit ports, so every raise goes
# through tx_gate.require_affirmation - one ssh call per channel, once per run. An
# earlier version pre-seeded Board._tx_affirmed, which made that check a no-op: the
# script raised output on TX2A with the gate never consulted, while the README said it
# refused without an affirmation. Do not re-add that to save a round trip.
import sdr_selftest as ST
b = ST.Board("ip:192.168.2.1"); b.save_state()
FS_DEC = 383999.0

def spec(iq, fs):
    iq = np.asarray(iq); iq = iq - iq.mean()
    nfft = 1 << 14; n = min(len(iq), nfft)
    P = 10*np.log10(np.abs(np.fft.fftshift(np.fft.fft(iq[:n]*np.hanning(n), nfft)))**2 + 1e-30)
    f = np.fft.fftshift(np.fft.fftfreq(nfft, 1/fs))
    return f, P

def at(f, P, target, bw=4e3):
    m = np.abs(f - target) < bw
    return float(P[m].max())

def floor(f, P):
    m = np.abs(f) > 5e3
    return float(np.median(P[m]))

try:
    b.wr(ST.PHY, "voltage0", "sampling_frequency", 3072000)
    for pair, pad in ((0, 20), (1, 30)):
        b.wr(ST.PHY, ST.RX_LO, "frequency", 900000000, True)
        b.wr(ST.PHY, ST.TX_LO, "frequency", 900000000, True)
        b.wr(ST.PHY, ST.TX_LO, "powerdown", 0, True)
        b.set_rx_gain(40, pair)
        phy = float(b.rd(ST.PHY, "voltage0", "sampling_frequency"))
        b.c.write_device(b.dev[ST.RX][0], "in_voltage_sampling_frequency", str(int(FS_DEC)))
        deliv = float(b.c.read_device(b.dev[ST.RX][0], "in_voltage_sampling_frequency"))
        # in-band reference at +50 kHz
        sent = b.tx_tone(50e3, phy, 20000, pair=pair); b.set_tx_atten(-30, pair)
        f, P = spec(b.capture(1 << 15, pair), deliv); ref = at(f, P, sent); fl_ref = floor(f, P); b.tx_stop()
        # out of band at +600 kHz; where would it land if it aliased?
        sent_o = b.tx_tone(600e3, phy, 20000, pair=pair); b.set_tx_atten(-30, pair)
        f, P = spec(b.capture(1 << 15, pair), deliv); fl = floor(f, P); b.tx_stop()
        a = ((sent_o + deliv/2) % deliv) - deliv/2        # folded frequency
        lvl = at(f, P, a)
        print(f"  TX{pair+1}->RX{pair+1} ({pad} dB), delivered {deliv/1e3:.1f} kSPS")
        print(f"    in-band  {sent/1e3:+7.2f} kHz -> {ref-fl_ref:6.1f} dB over floor   (the reference)")
        print(f"    out-of-band {sent_o/1e3:+7.1f} kHz would alias to {a/1e3:+7.2f} kHz")
        print(f"       level there: {lvl-fl:6.1f} dB over floor"
              f"   -> anti-alias rejection {(ref-fl_ref)-(lvl-fl):5.1f} dB")
    b.c.write_device(b.dev[ST.RX][0], "in_voltage_sampling_frequency", "3071997")
    b.restore_state()

finally:
    # ALWAYS put the receiver back. This script changes the DELIVERED sample rate on
    # cf-ad9361-lpc, and an abort - the gate refusing, a failed assertion, Ctrl-C -
    # used to leave it decimated. A decimated receiver then fails the selftest's
    # internal-loopback tone with no hint why, which is exactly what happened.
    try: b.c.write_device(b.dev[ST.RX][0], "in_voltage_sampling_frequency", "3071997")
    except Exception: pass
    try: b.restore_state()
    except Exception: pass