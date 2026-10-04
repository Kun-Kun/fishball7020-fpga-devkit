#!/usr/bin/env python3
"""Where does the chirp's mirror come from? An IQ-image test on the bench loop.

TX1 -> 20 dB pad -> RX1. A single tone, full 16-bit samples through libiio at
4.8 MS/s. The image of a tone at +f above an LO appears at -f below it, and
both the transmitter and the receiver make one. With both LOs equal they land
on the same spot; tuning TX1 0.3 MHz away from RX1 separates them.

    # run from: tools/chirp-view
    python mirror_test.py
"""
import time

import adi
import numpy as np

URI, RATE, RX_LO, N = "ip:fishball.local", 4_800_000, 866_950_000, 1 << 18
TONE_RF = RX_LO + 1_050_000           # where the app's chirp centre sat: 1.05 MHz above the LO
MUTED = -89.75

sdr = adi.ad9361(uri=URI)


def mute():
    for ch in (0, 1):
        setattr(sdr, f"tx_hardwaregain_chan{ch}", MUTED)
    assert sdr.tx_hardwaregain_chan0 <= MUTED + 0.26 and sdr.tx_hardwaregain_chan1 <= MUTED + 0.26


def capture():
    sdr.rx_destroy_buffer()                           # samples from after the change
    sdr.rx()
    spec = np.zeros(N)
    win = np.blackman(N)
    for _ in range(4):
        x = sdr.rx()
        spec += np.abs(np.fft.fftshift(np.fft.fft(x * win))) ** 2
    f = np.fft.fftshift(np.fft.fftfreq(N, 1 / RATE))
    return f, 10 * np.log10(spec / spec.max())


def level(f, s, at):
    k = np.argmin(np.abs(f - at))
    return s[k - 8:k + 9].max()


def case(name, tx_lo, notes=""):
    """Play the tone with TX1's LO at tx_lo; report the tone and both images."""
    bb = TONE_RF - tx_lo                              # the tone in TX1's own band
    n = int(round(RATE / 1000)) * 16                  # whole cycles of 1 kHz-spaced tones
    t = np.arange(n) / RATE
    iq = 0.5 * 2 ** 15 * np.exp(2j * np.pi * bb * t)
    sdr.tx_lo = int(tx_lo)
    sdr.tx_cyclic_buffer = True
    sdr.tx(iq)
    for _ in range(10):                               # AFTER the start: set, read back
        sdr.tx_hardwaregain_chan0 = -40
        sdr.tx_hardwaregain_chan1 = MUTED
        if abs(sdr.tx_hardwaregain_chan0 + 40) < 0.3:
            break
    else:
        mute(); sdr.tx_destroy_buffer(); raise RuntimeError("TX1 attenuation did not apply")
    time.sleep(0.3)
    f, s = capture()
    mute()                                            # mute FIRST, then tear down
    sdr.tx_destroy_buffer()
    main = TONE_RF - RX_LO
    rx_img = -main                                    # RX image: mirrored about RX LO
    tx_img = (tx_lo - (TONE_RF - tx_lo)) - RX_LO      # TX image: mirrored about TX LO, seen by RX
    m = level(f, s, main)
    print(f"{name}")
    print(f"   tone      {main/1e6:+.3f} MHz   {m:6.1f} dB")
    if abs(rx_img - tx_img) < 20e3:
        print(f"   image     {rx_img/1e6:+.3f} MHz   {level(f, s, rx_img) - m:6.1f} dBc  (TX and RX images together)")
    else:
        print(f"   RX image  {rx_img/1e6:+.3f} MHz   {level(f, s, rx_img) - m:6.1f} dBc")
        print(f"   TX image  {tx_img/1e6:+.3f} MHz   {level(f, s, tx_img) - m:6.1f} dBc")
    noise = np.median(s)
    print(f"   floor     {noise - m:6.1f} dBc {notes}")


try:
    mute()
    sdr.sample_rate = RATE
    sdr.rx_lo = RX_LO
    sdr.rx_rf_bandwidth = RATE
    sdr.tx_rf_bandwidth = RATE
    sdr.rx_enabled_channels = [0]
    sdr.tx_enabled_channels = [0]
    sdr.rx_buffer_size = N
    sdr.gain_control_mode_chan0 = "manual"
    sdr.rx_hardwaregain_chan0 = 30
    phy = sdr._ctrl
    q = phy.find_channel("voltage0", False)

    case("1. as in the app: TX and RX tuned the same", RX_LO)
    case("2. TX1 tuned 0.3 MHz above RX1: the two images apart", RX_LO + 300_000)
    q.attrs["quadrature_tracking_en"].value = "0"
    case("3. as 2, RX quadrature tracking OFF", RX_LO + 300_000)
    q.attrs["quadrature_tracking_en"].value = "1"
    phy.attrs["calib_mode"].value = "tx_quad"      # a fresh TX quadrature calibration
    time.sleep(0.5)
    phy.attrs["calib_mode"].value = "auto"
    case("4. as 2, after a fresh TX quadrature calibration", RX_LO + 300_000)
finally:
    mute()
    try:
        sdr.tx_destroy_buffer()
    except Exception:
        pass
    sdr.rx_destroy_buffer()
    q = sdr._ctrl.find_channel("voltage0", False)
    q.attrs["quadrature_tracking_en"].value = "1"
    print(f"\nTX1 {sdr.tx_hardwaregain_chan0} dB, TX2 {sdr.tx_hardwaregain_chan1} dB; "
          f"RX quadrature tracking {q.attrs['quadrature_tracking_en'].value}")
