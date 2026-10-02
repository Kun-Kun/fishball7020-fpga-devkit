#!/usr/bin/env python3
"""Check the ADS-B decoder with no board and no antenna.

    # run from: the repo root
    python3 tools/adsb/test_adsb.py        # needs numpy; exits non-zero on failure

The expected values are not from memory: every one was produced by pyModeS
2.x (an independent decoder) on the same input, and the field decoders were
compared with it over all 8192 altitude and squawk codes. The demodulator is
checked end to end on samples made by demod.modulate(): PPM pulses with a
random carrier phase, a frequency offset and noise, cut into blocks that split
messages across block boundaries.
"""

import json
import os
import pathlib
import subprocess
import sys
import tempfile

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import demod   # noqa: E402
import modes   # noqa: E402
from source import Recorder   # noqa: E402

fails = []


def check(name, ok, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""))
    if not ok:
        fails.append(name)


H = bytes.fromhex
IDENT = H("8D4840D6202CC371C32CE0576098")
EVEN = H("8D40621D58C382D690C8AC2863A7")
ODD = H("8D40621D58C386435CC412692AD6")
VEL_GS = H("8D485020994409940838175B284F")
VEL_AS = H("8DA05F219B06B6AF189400CBC33F")
DF5 = H("2A00516D492B80")
DF4 = H("20001838CA3804")

print("checksum")
for m in (IDENT, EVEN, ODD, VEL_GS, VEL_AS):
    check(f"DF17 {m.hex()[:8]} has remainder 0", modes.syndrome(m) == 0)
check("DF5's remainder is its address/parity", modes.syndrome(DF5) == 0x510AF9)
bad = bytearray(IDENT)
bad[7] ^= 0x10
st, icao, fixed = modes.check(bytes(bad))
check("one flipped bit in DF17 is repaired", st == "fixed" and fixed == IDENT and icao == 0x4840D6)
bad[9] ^= 0x01
check("two flipped bits are rejected", modes.check(bytes(bad))[0] is None)
check("DF5 is untrusted from an unknown address", modes.check(DF5)[0] is None)
check("DF5 is trusted once its address is known", modes.check(DF5, {0x510AF9})[0] == "addr")

print("fields")
d = modes.decode(IDENT)
check("callsign KLM1023", d.get("callsign") == "KLM1023", d.get("callsign"))
d = modes.decode(EVEN)
check("airborne position: 38000 ft, even", d.get("altitude") == 38000 and d.get("odd") is False)
d = modes.decode(VEL_GS)
check("ground speed 159 kt, track 182.9, -832 fpm",
      (d["speed"], d["track"], d["vrate"], d["speed_kind"]) == (159, 182.9, -832, "GS"), d)
d = modes.decode(VEL_AS)
check("airspeed 375 kt TAS, heading 244.0, -2304 fpm",
      (d["speed"], d["track"], d["vrate"], d["speed_kind"]) == (375, 244.0, -2304, "TAS"), d)
check("DF5 squawk 0356", modes.decode(DF5).get("squawk") == "0356")
check("DF4 altitude 38000 ft", modes.decode(DF4).get("altitude") == 38000)
for code, feet in ((7687, 79400), (2467, 35700), (4226, 6200), (1705, 52500)):
    check(f"Gillham code {code} is {feet} ft", modes.altitude_ac13(code) == feet,
          modes.altitude_ac13(code))

print("position")
e, o = modes.decode(EVEN)["cpr"], modes.decode(ODD)["cpr"]
lat, lon = modes.cpr_global(e, o, latest_odd=True)
check("even/odd pair -> 52.26578, 3.93891", abs(lat - 52.26578) < 1e-4 and abs(lon - 3.93891) < 1e-4,
      f"{lat:.5f}, {lon:.5f}")
lat, lon = modes.cpr_local(e, False, 52.258, 3.918)
check("one message + reference -> 52.25720, 3.91937",
      abs(lat - 52.25720) < 1e-4 and abs(lon - 3.91937) < 1e-4, f"{lat:.5f}, {lon:.5f}")
t = modes.Tracker()
t.feed(EVEN, now=100.0)
t.feed(ODD, now=101.0)
a = t.aircraft[0x40621D]
check("the tracker pairs them", a.lat is not None and abs(a.lat - 52.26578) < 1e-4)
t2 = modes.Tracker()
t2.feed(EVEN, now=100.0)
t2.feed(ODD, now=130.0)
check("...but not 30 s apart", t2.aircraft[0x40621D].lat is None)

print("demodulator")
msgs = [IDENT, EVEN, ODD, VEL_GS, VEL_AS] * 60


def demodulate(iq, sizes=None, noise=None):
    """Trusted (sample, bytes) pairs, feeding blocks of the given sizes."""
    d = demod.Demodulator(4e6, noise=noise)
    frames, k, i = [], 0, 0
    while k < len(iq):
        n = sizes[i] if sizes else len(iq)
        frames += d.feed(iq[k:k + n])
        k, i = k + n, i + 1
    return {(f.sample, modes.check(f.msg)[2]) for f in frames
            if modes.check(f.msg)[0] in ("ok", "fixed")}, frames


FLOOR = 48.0           # the chip-energy median of noise=20 at 4 MSPS
ragged = [int(n) for n in np.random.default_rng(7).integers(500, 40000, 5000)]
for label, amp, drift, need in (("strong", 2000, 0.0, 1.0), ("12 dB", 80, 0.0, 0.98),
                                ("12 dB, 50 kHz off", 80, 2 * np.pi * 50e3 / 4e6, 0.98)):
    iq, starts = demod.modulate(msgs, amplitude=amp, noise=20, phase_drift=drift,
                                offset_samples=1)
    _, frames = demodulate(iq, ragged)
    cut = {(f.sample, modes.check(f.msg)[2]) for f in frames
           if modes.check(f.msg)[0] in ("ok", "fixed")}
    # The noise floor is a running estimate, so it moves a little with how the
    # stream is cut; pin it to compare the boundary handling and nothing else.
    whole, _ = demodulate(iq, noise=FLOOR)
    pinned, _ = demodulate(iq, ragged, noise=FLOOR)
    right = sum(1 for n, m in cut if m == msgs[starts.index(n)]) if cut else 0
    check(f"{label}: at least {need:.0%} of {len(msgs)} decode, each once, correctly",
          right >= need * len(msgs) and right == len(cut) and len(frames) <= len(msgs),
          f"{right} right of {len(frames)} found")
    check(f"{label}: cutting the samples into blocks changes nothing", whole == pinned,
          f"{len(whole ^ pinned)} differ")
noise = (np.random.default_rng(9).standard_normal(20_000_000)
         .astype(np.float32).view(np.complex64) * 20)
d = demod.Demodulator(4e6)
found = [f for k in range(0, len(noise), 1 << 20) for f in d.feed(noise[k:k + (1 << 20)])]
trusted = [f for f in found if modes.check(f.msg)[0]]
check("5 s of pure noise: no trusted message", not trusted, f"{len(found)} preambles")
try:
    demod.Demodulator(2.4e6)
    check("2.4 MSPS is refused (not a multiple of 2 MHz)", False)
except ValueError:
    check("2.4 MSPS is refused (not a multiple of 2 MHz)", True)

print("the command, replaying a recording")
with tempfile.TemporaryDirectory() as tmp:
    iq, _ = demod.modulate([IDENT, EVEN, ODD, VEL_GS] * 10, amplitude=300, noise=15)
    r = Recorder(os.path.join(tmp, "rec"), {"sample_rate": 4_000_000, "frequency": 1_090_000_000})
    r.write(iq)
    r.close()
    out = subprocess.run([sys.executable, str(HERE / "adsb.py"), "--text", "--json", "--fast",
                          "--replay", os.path.join(tmp, "rec.sigmf-meta")],
                         capture_output=True, text=True, timeout=60)
    try:
        got = json.loads(out.stdout)
        planes = {a["icao"]: a for a in got["aircraft"]}
        ok = (out.returncode == 0 and planes["4840D6"]["callsign"] == "KLM1023"
              and abs(planes["40621D"]["lat"] - 52.26578) < 1e-4
              and planes["485020"]["speed"] == 159 and got["stats"]["ok"] == 40)
        check("--replay --json: three aircraft, all 40 messages", ok, got["stats"])
    except (ValueError, KeyError) as e:
        check("--replay --json: three aircraft, all 40 messages", False,
              f"{e}; exit {out.returncode}; {out.stderr.strip()[-200:]}")

print(f"\n{'FAILED: ' + ', '.join(fails) if fails else 'all ADS-B checks pass'}")
sys.exit(1 if fails else 0)
