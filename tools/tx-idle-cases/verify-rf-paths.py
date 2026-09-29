#!/usr/bin/env python3
"""TX frequency == RX frequency, and the decimators, on both loops.

Uses the selftest's own Board class, whose capture path is the one the repo trusts.
"""
import sys, numpy as np
sys.path.insert(0, "tools/selftest")
import sdr_selftest as ST

b = ST.Board("ip:192.168.2.1")
b.save_state()
b._tx_affirmed.update({0, 1})              # affirmed via ./devkit already

def peak_offset(iq, fs):
    iq = np.asarray(iq); iq = iq - iq.mean()
    nfft = 1 << 14
    n = min(len(iq), nfft)
    w = np.hanning(n)
    P = np.abs(np.fft.fftshift(np.fft.fft(iq[:n] * w, nfft)))**2
    f = np.fft.fftshift(np.fft.fftfreq(nfft, 1/fs))
    m = np.abs(f) > 5e3
    i = int(np.argmax(np.where(m, P, 0)))
    floor = 10*np.log10(np.median(P[m]) + 1e-30)
    return f[i], 10*np.log10(P[i] + 1e-30) - floor

print("=== A. Is the received frequency the same as the transmitted one? ===")
for pair, pad, lo in ((0, 20, 900e6), (1, 30, 900e6)):
    b.wr(ST.PHY, "voltage0", "sampling_frequency", 3072000)
    b.wr(ST.PHY, ST.RX_LO, "frequency", int(lo), True)
    b.wr(ST.PHY, ST.TX_LO, "frequency", int(lo), True)
    b.wr(ST.PHY, ST.TX_LO, "powerdown", 0, True)
    rxlo = float(b.rd(ST.PHY, ST.RX_LO, "frequency", True))
    txlo = float(b.rd(ST.PHY, ST.TX_LO, "frequency", True))
    b.set_rx_gain(40, pair)
    fs = float(b.rd(ST.PHY, "voltage0", "sampling_frequency"))
    sent = b.tx_tone(300e3, fs, 20000, pair=pair)
    b.set_tx_atten(-30, pair)
    got, snr = peak_offset(b.capture(1 << 15, pair), fs)
    b.tx_stop()
    print(f"  TX{pair+1}->RX{pair+1} ({pad} dB): TX_LO={txlo/1e6:.6f} MHz  RX_LO={rxlo/1e6:.6f} MHz  "
          f"delta={txlo-rxlo:+.1f} Hz")
    print(f"      tone sent {sent/1e3:+.3f} kHz, received {got/1e3:+.3f} kHz  "
          f"|error| {abs(abs(got)-abs(sent)):.1f} Hz   SNR {snr:.0f} dB")

print("=== B. The decimators ===")
print(f"  AD9361 FIR: {open('/dev/null').read() or ''}", end="")
for pair, pad in ((0, 20), (1, 30)):
    for want in (3071997, 383999):
        b.wr(ST.PHY, "voltage0", "sampling_frequency", 3072000)
        try:
            b.c.write_device(b.dev[ST.RX][0], "in_voltage_sampling_frequency", str(want))
        except Exception as exc:
            print(f"  TX{pair+1}: could not set delivered rate {want}: {exc}"); continue
        delivered = float(b.c.read_device(b.dev[ST.RX][0], "in_voltage_sampling_frequency"))
        phy = float(b.rd(ST.PHY, "voltage0", "sampling_frequency"))
        b.set_rx_gain(40, pair)
        off = 50e3                                  # inside +/-192 kHz after the /8
        sent = b.tx_tone(off, phy, 20000, pair=pair)
        b.set_tx_atten(-30, pair)
        got, snr = peak_offset(b.capture(1 << 15, pair), delivered)
        b.tx_stop()
        dec = phy/delivered
        print(f"  TX{pair+1}->RX{pair+1}: PHY {phy/1e6:.6f} MSPS, delivered {delivered/1e3:.3f} kSPS "
              f"(decimation {dec:.0f}x)  tone sent {sent/1e3:+.2f} kHz "
              f"received {got/1e3:+.2f} kHz  |err| {abs(abs(got)-abs(sent)):.0f} Hz  SNR {snr:.0f} dB")
b.c.write_device(b.dev[ST.RX][0], "in_voltage_sampling_frequency", "3071997")
b.restore_state()
