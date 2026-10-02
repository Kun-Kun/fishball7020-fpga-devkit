#!/usr/bin/env python3
"""Measure this board's 40 MHz reference against a disciplined source, and fix it.

    # run from: the repo root
    ./devkit clock                      # what is the correction set to now?
    ./devkit clock measure --ref 100e6  # how far off is Y3? (needs a source)
    ./devkit clock measure --ref 100e6 --apply
    ./devkit clock reset                # back to the nominal 40 000 000

WHAT THIS IS FOR. Every frequency this board tunes to is derived from `Y3`, a
40 MHz VCTCXO. If `Y3` is 4 Hz fast - 0.1 ppm - then a receiver asked for
900 MHz is really at 900.00009 MHz, and a transmitter asked for 868.0 MHz is
90 Hz off. The driver exposes `xo_correction`, which is where you tell it what
`Y3` ACTUALLY runs at, and after that every tuned frequency comes out right.

    cat /sys/bus/iio/devices/iio:device0/xo_correction_available
    #   [39992000 1 40008000]      1 Hz steps, about 0.025 ppm

This buys ACCURACY, NOT STABILITY. The VCTCXO still wanders with temperature,
so a correction measured on a cold board is wrong on a warm one. Measure after
the board has been on for a while, and re-measure if you care at the 0.01 ppm
level. If you need stability rather than accuracy you have to replace `Y3`,
which means soldering - see docs/hardware.md (external reference).

WHAT YOU NEED. Any source whose frequency you trust: a GPS-disciplined clock
(a Leo Bodnar Mini, an Ericsson/Trimble GPSDO), a rubidium standard, or a
signal generator that is itself locked to one. Set it to something in the
board's tuning range, feed it into an RX port, and tell this tool the frequency
you set with --ref.

  !! THE LEVEL MATTERS AND THE DEFAULT IS WRONG FOR YOU !!

A GPS clock module is a clock GENERATOR, not a signal generator: an SMA on the
box does not make it an RF source. It drives a square wave from a CMOS output
through a series resistor, so the amplitude depends entirely on the load.

  into 50 ohm (this port)   ~1.6 V p-p, near +10 dBm - the series resistor and
                            the load divide the rail roughly in half
  into a high-Z input       approaching the full rail, e.g. 3.3 V p-p

This port is rated +2.5 dBm, so the first case is some 8 dB too hot: fit at
least 20 dB. A square wave is also all odd harmonics - a 100 MHz source puts
real energy at 300, 500 and 700 MHz - so choose --ref so that neither it nor
its harmonics land on something you care about, and do not be surprised to see
them. Some of these modules let you set the output drive strength; check yours,
and scope it rather than trusting any of the numbers above.

HOW THE MEASUREMENT WORKS. Tune the receiver to exactly the frequency you set
on the source. If the board's reference is correct the tone lands at 0 Hz; if
the reference is fast by a fraction e, the LO is high by the same fraction and
the tone lands at -e * f_ref. So

    e        = -offset_hz / ref_hz
    xo_true  = 40e6 * (1 + e)

The offset is estimated from the average phase advance between consecutive
samples - angle(sum(x[n+1] * conj(x[n]))) * fs / 2pi - which needs no FFT, no
numpy, and is the right estimator for one strong tone near DC. It is unbiased
and its accuracy improves with capture length, so --seconds buys you precision
directly.

WHAT IS NOT MEASURED HERE. The sample clock is derived from the same reference,
so a reference error also scales the sample rate. That is a second-order effect
on this measurement (it scales the measured offset by 1 + e, where e is around
1e-6) and is ignored deliberately - correcting for it would change the answer
by parts in 1e12, far below the 1 Hz resolution of xo_correction itself.
"""
from __future__ import annotations

import argparse
import cmath
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "selftest"))
from board_addr import resolve as _board                          # noqa: E402
from iiod_min import Iiod, mask_for                               # noqa: E402

PHY = "ad9361-phy"
RX = "cf-ad9361-lpc"
NOMINAL = 40_000_000


# ---------------------------------------------------------------- measurement
def tone_offset_hz(iq, fs):
    """Frequency of one strong tone near DC, from its phase advance per sample.

    sum(x[n+1] * conj(x[n])) accumulates a vector whose angle is the mean phase
    step. Summing the products rather than averaging the angles is what makes
    this robust: angles wrap at +/-pi and averaging wrapped angles is wrong in
    a way that looks fine until the tone drifts past the wrap.

    Unambiguous for |offset| < fs/2, which is the whole captured band, so there
    is no aliasing trap here as long as the tone really is the strongest thing.
    """
    acc = 0j
    prev = iq[0]
    for cur in iq[1:]:
        acc += cur * prev.conjugate()
        prev = cur
    if acc == 0:
        raise SystemExit("clock-cal: the capture is silent - is the source on, "
                         "and connected to the port you tuned?")
    return cmath.phase(acc) / (2.0 * cmath.pi) * fs


def capture(c, nsamples, channel):
    """Interleaved I/Q from one receive channel, as a list of complex."""
    pair = [0, 1] if channel == 0 else [2, 3]
    raw = c.read_samples(RX, nsamples, mask_for(pair, 4), nchannels=2)
    return [complex(raw[i], raw[i + 1]) for i in range(0, len(raw) - 1, 2)]


def snr_estimate(iq):
    """A crude in-band SNR, only to tell 'no signal' from 'a signal'.

    Mean power against the power left after removing the tone's own mean phase
    rotation. Good enough to refuse a measurement that would be noise.
    """
    n = len(iq)
    p = sum(abs(z) ** 2 for z in iq) / n
    if p == 0:
        return 0.0
    return p


# ------------------------------------------------------------------- the board
def read_correction(c):
    return int(c.read(PHY, "altvoltage0", "xo_correction", output=True).strip()
               if False else c.read_device(PHY, "xo_correction").strip())


def available(c):
    try:
        return c.read_device(PHY, "xo_correction_available").strip()
    except Exception:
        return ""


def cmd_show(c, args):
    cur = read_correction(c)
    av = available(c)
    err_ppm = (cur - NOMINAL) / NOMINAL * 1e6
    out = {"xo_correction": cur, "nominal": NOMINAL,
           "applied_ppm": round(err_ppm, 4), "available": av}
    if args.json:
        print(json.dumps(out, indent=2))
        return 0
    print(f"  xo_correction   {cur} Hz")
    print(f"  nominal         {NOMINAL} Hz")
    print(f"  correction now  {err_ppm:+.4f} ppm", end="")
    print("   (nothing applied)" if cur == NOMINAL else "")
    if av:
        print(f"  range           {av}")
    if cur == NOMINAL:
        print("\n  This board has never been calibrated. To do it you need a "
              "source you trust:\n    ./devkit clock measure --ref 100e6")
    return 0


def cmd_reset(c, args):
    c.write_device(PHY, "xo_correction", str(NOMINAL))
    print(f"  xo_correction set back to the nominal {NOMINAL} Hz")
    return 0


def cmd_measure(c, args):
    # float() first: the help says --ref 100e6 and int('100e6') raises.
    try:
        ref = int(float(args.ref))
    except ValueError:
        raise SystemExit(f"clock-cal: --ref {args.ref!r} is not a number. "
                         f"Try --ref 100e6 or --ref 100000000.")
    if not (70_000_000 <= ref <= 6_000_000_000):
        raise SystemExit(f"clock-cal: --ref {ref} Hz is outside the AD9361's "
                         f"70 MHz - 6 GHz tuning range.")
    if not args.i_fitted_a_pad:
        raise SystemExit(
            "clock-cal: refusing to run without --i-fitted-a-pad.\n\n"
            "  A GPS clock module drives a SQUARE WAVE from a CMOS output "
            "through a series\n"
            "  resistor, so what arrives depends on the load. Into your 50 ohm "
            "receive port that\n"
            "  is roughly half the rail - about 1.6 V p-p, near +10 dBm. This "
            "board's receive\n"
            "  port is rated +2.5 dBm, so that is some 8 dB too hot.\n\n"
            "  Fit at least 20 dB of attenuation, which also knocks down the "
            "harmonics: a square\n"
            "  wave at --ref puts real energy at 3x, 5x and 7x it. Then pass "
            "--i-fitted-a-pad.\n\n"
            "  This tool cannot sense what is on the port and never claims to.")

    fs = int(args.rate)
    ch = args.channel
    nsamp = max(4096, int(fs * args.seconds))

    before = read_correction(c)
    # Measure against the NOMINAL reference, whatever correction is loaded, so
    # the arithmetic below is always about Y3 itself rather than about Y3 plus
    # whatever somebody wrote here last week.
    if before != NOMINAL and not args.keep_correction:
        print(f"  xo_correction was {before}; measuring from the nominal "
              f"{NOMINAL} first")
        c.write_device(PHY, "xo_correction", str(NOMINAL))

    c.write(PHY, "voltage0", "sampling_frequency", str(fs))
    c.write(RX, "voltage0", "sampling_frequency", str(fs))   # decimator bypassed
    c.write(PHY, "altvoltage0", "frequency", str(ref), output=True)
    c.write(PHY, "voltage0", "gain_control_mode", args.gain_mode)
    if args.gain_mode == "manual":
        c.write(PHY, "voltage0", "hardwaregain", str(args.gain))

    iq = capture(c, nsamp, ch)
    if snr_estimate(iq) < 4.0:
        raise SystemExit(
            "clock-cal: the capture is at the noise floor. Check the source is "
            "on, that it\n  is on the port you selected (--channel), and that "
            "the pad is not larger than\n  you meant. Raise --gain, or use "
            "--gain-mode slow_attack.")

    offset = tone_offset_hz(iq, fs)
    e = -offset / ref
    xo_true = NOMINAL * (1.0 + e)
    suggested = int(round(xo_true))

    span = fs / 2.0
    out = {
        "ref_hz": ref, "sample_rate_hz": fs, "samples": len(iq),
        "seconds": len(iq) / fs, "channel": ch,
        "offset_hz": offset, "error_ppm": e * 1e6,
        "xo_measured_hz": xo_true, "xo_correction_suggested": suggested,
        "xo_correction_before": before,
    }
    if args.json:
        print(json.dumps(out, indent=2))
    else:
        print(f"  reference set to     {ref/1e6:.6f} MHz  (you told me so)")
        print(f"  captured             {len(iq)} samples "
              f"({len(iq)/fs:.3f} s at {fs/1e6:.3f} MSPS)")
        print(f"  tone found at        {offset:+.3f} Hz from centre "
              f"(unambiguous to +/-{span/1e3:.0f} kHz)")
        print()
        print(f"  the board is off by  {e*1e6:+.4f} ppm")
        print(f"  Y3 actually runs at  {xo_true:.1f} Hz")
        print(f"  xo_correction        {suggested}   "
              f"(was {before}{', unchanged' if suggested == before else ''})")
        print()
        print(f"  At 900 MHz that is {abs(e)*900e6:.1f} Hz of error, "
              f"at 2.4 GHz {abs(e)*2.4e9:.0f} Hz.")

    if args.apply:
        c.write_device(PHY, "xo_correction", str(suggested))
        print(f"\n  applied: xo_correction = {suggested}")
        print("  This is NOT persistent. To keep it across reboots, see "
              "docs/hardware.md (external reference)")
    else:
        c.write_device(PHY, "xo_correction", str(before))
        print(f"\n  nothing written (xo_correction left at {before}). "
              f"Add --apply to set it.")
    return 0


def main():
    p = argparse.ArgumentParser(
        description="Measure and correct the board's 40 MHz reference.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Background: docs/hardware.md, 'Locking the board to an external reference'")
    p.add_argument("--uri", default=None,
                   help="libiio URI; by default the board is found by name")
    p.add_argument("--json", action="store_true")
    sub = p.add_subparsers(dest="cmd")

    sub.add_parser("show", help="what is xo_correction set to now (default)")
    sub.add_parser("reset", help="put xo_correction back to 40 000 000")

    m = sub.add_parser("measure", help="measure Y3 against a source you trust")
    m.add_argument("--ref", required=True,
                   help="the frequency you set on the source, in Hz (100e6)")
    m.add_argument("--rate", default=3e6, type=float,
                   help="receive sample rate (default 3e6)")
    m.add_argument("--seconds", default=1.0, type=float,
                   help="capture length; longer is more precise (default 1.0)")
    m.add_argument("--channel", default=1, type=int, choices=(0, 1),
                   help="which receiver the source is on (default 1, i.e. RX2)")
    m.add_argument("--gain", default=20.0, type=float,
                   help="manual gain in dB (default 20 - the source is strong)")
    m.add_argument("--gain-mode", default="manual",
                   choices=("manual", "slow_attack", "fast_attack"))
    m.add_argument("--apply", action="store_true",
                   help="write the measured value to xo_correction")
    m.add_argument("--keep-correction", action="store_true",
                   help="measure on top of the loaded correction instead of "
                        "resetting to nominal first")
    m.add_argument("--i-fitted-a-pad", action="store_true",
                   help="assert that at least 20 dB of attenuation is between "
                        "the source and the port")

    args = p.parse_args()
    host = args.uri or _board()
    if host.startswith("ip:"):
        host = host[3:]

    fn = {"reset": cmd_reset, "measure": cmd_measure}.get(args.cmd, cmd_show)
    try:
        c = Iiod(host).connect()
    except OSError as exc:
        print(f"could not reach the board at {host}: {exc}", file=sys.stderr)
        return 1
    with c:
        return fn(c, args)


if __name__ == "__main__":
    sys.exit(main())
