#!/usr/bin/env python3
"""Every die temperature this board can measure, against its rating.

    # run from: the repo root
    ./devkit temps                 # LIVE, refreshing in place, until Ctrl-C
    ./devkit temps --once          # a single reading
    ./devkit temps --json          # for scripts (one reading)

Live is the default because a single number rarely answers the question. What
you actually want to know is whether the die is still climbing, and how far it
got - so the live view keeps the minimum, the maximum and the direction of
travel since you started, next to the current reading.

Piping or redirecting turns live off by itself: an in-place display written to
a file is unreadable, so a non-tty gets one reading unless you ask for --live.

The board has exactly **two** temperature sensors, and it is worth knowing that
up front so you do not go looking for a third:

    Zynq XC7Z020   read through the XADC, the Zynq's own on-die converter
    AD9361         read through the transceiver's internal AuxADC

There is no sensor on the PGA-102+ power amplifiers, the DDR, the Ethernet PHY
or the regulators, and no `hwmon` or thermal-zone entries at all - checked on
the board, not assumed. So "the board is at N degrees" is never something this
tool can tell you; it reports two dies and says which.

WHERE THE RATINGS COME FROM. The two are not equally solid, so they are not
presented as though they were.

ZYNQ - read from the datasheet. DS190, Zynq-7000 SoC Data Sheet: Overview
(v1.11.1, 2 July 2018), Table 7 "Speed Grade and Temperature Ranges":

    Commercial (C)    Tj  0 C to  +85 C
    Extended   (E)    Tj  0 C to +100 C
    Industrial (I)    Tj -40 C to +100 C

and, for the XC7Z020 row, which grades exist at all:

    Commercial: -1 only        Extended: -2, -3        Industrial: -1, -2, -1L

That last line is the interesting part, and it corrects something this
repository has said for a while. The design targets `xc7z020clg400-2` - speed
grade -2, recorded in the hardware platform's sysdef.xml - and an XC7Z020 is
NOT sold as commercial in -2. So if the fitted part really is a -2, its
junction limit is +100 C, not +85 C, and calling 85 C "the commercial rating"
was wrong.

But the fitted part's temperature grade is not recorded anywhere reachable.
The vendor schematic and the factory inspection report both mark it only as
`XC7Z020-CLG400`, with no speed or temperature suffix, and the Vivado part
string is what ADI's project targets rather than what is soldered on. The
grade letter is on the chip itself; reading it off the package is the only way
to settle this.

So this tool warns at 85 C - the lowest rating the part could have - and
reports 100 C as the limit it probably has. Erring toward the cooler figure is
the right direction for a thermal warning.

AD9361 - read from the datasheet. AD9361 Data Sheet, Rev. G, Table 11
"Absolute Maximum Ratings":

    Maximum Junction Temperature (TJMAX)   110 C
    Operating Temperature Range            -40 C to +85 C
    Storage Temperature Range              -65 C to +150 C

Worth flagging, because this tool got it wrong before the datasheet was to
hand: the absolute maximum junction temperature is 110 C, NOT 150 C. 150 C is
the STORAGE maximum - a different row of the same table, and not a temperature
you may run the part at. The earlier figure overstated the headroom by 40 C.

Table 12 of the same datasheet gives the thermal resistance for the 144-ball
CSP_BGA as 32.3 C/W in still air, falling to 27.8 C/W at 2.5 m/s. That is the
number for turning dissipation into a temperature rise if you need to.

Both are the right SHAPE of limit: the XADC and the AuxADC each report
junction temperature, which is what these figures constrain.

The one thing still unresolved is the Zynq's temperature grade, and the answer
is on the chip package rather than in any document.

The transmitter is the only part here that heats itself appreciably, and the
amplifier sits next to the AD9361. If you want the board to act on this rather
than just report it, patch 0018 added a limit that refuses to raise transmit
power above a die temperature:

    # run on the board - millidegrees C, 0 disables
    echo 60000 > /sys/bus/iio/devices/iio:device0/tx_temp_limit
"""
from __future__ import annotations

import argparse
import collections
import shutil
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "selftest"))
from board_addr import resolve as _board                          # noqa: E402
from iiod_min import Iiod                                         # noqa: E402

PHY, XADC = "ad9361-phy", "xadc"

# name, spec limit (C), absolute max (C) or None, where the number comes from
SENSORS = [
    # 85 C is the CONSERVATIVE bound, not this part's known rating - see
    # --help. DS190 Table 7 gives 85 C only for commercial grade, and an
    # XC7Z020 is not sold as commercial in the -2 speed grade this design
    # targets; -2 is Extended or Industrial, both +100 C. The fitted part's
    # temperature grade is not recorded anywhere available, so warn at the
    # lowest rating it could have.
    ("Zynq XC7Z020", 85.0, 100.0,
     "85 C = worst case if commercial; -2 grade implies 100 C."
     " DS190 (v1.11.1) Table 7. --help explains."),
    ("AD9361", 85.0, 110.0,
     "85 C operating, 110 C max junction. AD9361 Rev. G Table 11."),
]

# Fractions of the spec limit at which to start saying something. Warning well
# before the limit is the point: by the time a die is AT its rating you have
# already been running it out of spec for a while.
WARN_AT = 0.80
HOT_AT = 0.94


def read_temps(c: Iiod) -> dict:
    """Both dies, in degrees C.

    The XADC reports a raw code with a separate offset and scale, exactly as
    tools/selftest does it; the AD9361 reports millidegrees directly.
    """
    raw = float(c.read(XADC, "temp0", "raw"))
    off = float(c.read(XADC, "temp0", "offset"))
    scale = float(c.read(XADC, "temp0", "scale"))
    zynq = (raw + off) * scale / 1000.0
    ad9361 = float(c.read(PHY, "temp0", "input")) / 1000.0
    return {"Zynq XC7Z020": zynq, "AD9361": ad9361}


def verdict(temp: float, limit: float) -> tuple[str, str]:
    """(label, ansi colour) for one reading."""
    if temp >= limit:
        return "OVER LIMIT", "\033[31m"
    if temp >= limit * HOT_AT:
        return "hot", "\033[31m"
    if temp >= limit * WARN_AT:
        return "warm", "\033[33m"
    return "ok", "\033[32m"


def render(temps: dict, colour: bool, extra: dict | None = None,
           sources: bool = True) -> str:
    out = []
    w = max(len(n) for n, _, _, _ in SENSORS)
    for name, limit, absmax, source in SENSORS:
        t = temps[name]
        label, col = verdict(t, limit)
        c0, c1 = (col, "\033[0m") if colour else ("", "")
        head = max(0.0, limit - t)
        line = (f"  {name:<{w}}  {t:6.1f} C   {c0}{label:<10}{c1}"
                f" {head:5.1f} C below the {limit:.0f} C limit")
        if absmax:
            line += f"  (absolute max {absmax:.0f} C)"
        out.append(line)
        if sources:
            out.append(f"  {'':<{w}}  {source}")
    if extra:
        out.append("")
        for k, v in extra.items():
            if k.startswith("_"):
                continue
            out.append(f"  {k}: {v}")
        for line in extra.get("_limit_lines", []):
            out.append(f"  {line}" if line else "")
    return "\n".join(out)


def tx_state(c: Iiod) -> dict:
    """What the transmitter is doing, since it is what heats the board."""
    info = {}
    try:
        a0 = c.read(PHY, "voltage0", "hardwaregain", output=True).split()[0]
        a1 = c.read(PHY, "voltage1", "hardwaregain", output=True).split()[0]
        info["transmit attenuation"] = f"TX1 {a0} dB, TX2 {a1} dB"
    except Exception:
        pass
    # A device attribute, not a channel one, and it only exists with patch
    # 0018 - so distinguish "the knob is missing" from "the knob is off".
    # Reporting them the same way would tell somebody to go install a patch
    # they already have.
    try:
        info["_tx_temp_limit_mC"] = int(c.read_device(PHY, "tx_temp_limit"))
    except Exception:
        info["_tx_temp_limit_mC"] = None
    return info


#: What to suggest when the limit is off. The AD9361 is specified to 85 C and
#: idles around 45 C on this board, so 70 C acts well before the rating while
#: leaving room for a warm room and a busy transmitter.
SUGGEST_C = 70


def tx_limit_lines(limit_mC, ad9361_c: float, host: str) -> list[str]:
    """What the thermal limit is, and exactly how to change it."""
    if limit_mC is None:
        return ["tx_temp_limit: absent - this firmware predates patch 0018.",
                "    Build and flash a current devkit kernel to get it."]

    if limit_mC:
        lim_c = limit_mC / 1000
        head = lim_c - ad9361_c
        return [
            f"tx_temp_limit: {lim_c:.1f} C - ACTIVE. Above this the driver",
            "    refuses to lower the attenuation, so transmit power cannot be",
            f"    raised. Muting is never blocked. AD9361 is at {ad9361_c:.1f} C,"
            + (f" {head:.1f} C below the limit." if head >= 0
               else f" {-head:.1f} C OVER the limit - transmit is being refused."),
            "    To turn it off:",
            f"        # run on your HOST",
            f"        iio_attr -u ip:{host} -d ad9361-phy tx_temp_limit 0",
        ]

    return [
        "tx_temp_limit: 0 - OFF. Nothing stops the board transmitting hot.",
        f"    To refuse transmit above {SUGGEST_C} C, either:",
        "",
        "        # run on your HOST",
        f"        iio_attr -u ip:{host} -d ad9361-phy tx_temp_limit {SUGGEST_C * 1000}",
        "",
        "        # or run on the board",
        f"        echo {SUGGEST_C * 1000} > /sys/bus/iio/devices/iio:device0/tx_temp_limit",
        "",
        "    The value is MILLIdegrees C, so 70 C is 70000. Above it, requests",
        "    to lower the attenuation are refused and muting still works - the",
        "    failure direction is silence, never a stuck-on transmitter.",
        "    It does NOT survive a reboot; the driver starts at 0. How to make",
        "    it stick depends on which rootfs the board runs - check with",
        "    `ssh root@BOARD grep ^ID= /etc/os-release`:",
        "",
        "      Debian    a systemd unit. Copy one of the five in",
        "                firmware-modern/debian/overlay/etc/systemd/system/.",
        "                /mnt/jffs2/autorun.sh is NOT run on this rootfs - a",
        "                script there will sit and do nothing.",
        "      Buildroot /mnt/jffs2/autorun.sh, which runs at every boot. Read",
        "                docs/kernel.md first: that partition survives",
        "                reflashing and is the usual reason a board behaves",
        "                unlike its firmware.",
    ]


BLOCKS_UTF8 = "\u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588"
BLOCKS_ASCII = "_.-~=+*#"


def _blocks() -> str:
    """Block characters if the terminal can encode them, ASCII if not."""
    enc = (sys.stdout.encoding or "ascii").lower()
    if "utf" not in enc:
        return BLOCKS_ASCII
    try:
        BLOCKS_UTF8.encode(sys.stdout.encoding)
        return BLOCKS_UTF8
    except (UnicodeEncodeError, LookupError, TypeError):
        return BLOCKS_ASCII


# The smallest temperature span a graph will stretch over. Without a floor,
# auto-scaling turns the XADC's few-tenths dither into a mountain range and the
# graph looks alarming while nothing is happening.
MIN_SPAN_C = 2.0


def sparkline(values, width: int, chars: str) -> tuple[str, float, float]:
    """A one-line graph of the last `width` samples, plus the span it covers."""
    vals = list(values)[-width:] if width > 0 else []
    if not vals:
        return "", 0.0, 0.0
    lo, hi = min(vals), max(vals)
    mid = (lo + hi) / 2.0
    if hi - lo < MIN_SPAN_C:                 # widen a flat trace to the floor
        lo, hi = mid - MIN_SPAN_C / 2, mid + MIN_SPAN_C / 2
    span = hi - lo
    n = len(chars) - 1
    return "".join(chars[max(0, min(n, round((v - lo) / span * n)))]
                   for v in vals), lo, hi


class Track:
    """Min, max and direction of travel per sensor.

    A live reading on its own is not much more useful than a one-shot one. The
    question being asked is almost always "is it still going up, and how far
    did it get" - so keep the extremes and the last delta, and show them.
    """

    def __init__(self, keep: int = 240):
        self.lo: dict[str, float] = {}
        self.hi: dict[str, float] = {}
        self.prev: dict[str, float] = {}
        self.delta: dict[str, float] = {}
        # Bounded, so a watch left running overnight cannot grow without limit.
        # 240 samples is 8 minutes at the default 2 s interval, and more than
        # any sensible terminal is wide.
        self.hist: dict[str, collections.deque] = {}
        self.keep = keep

    def update(self, temps: dict) -> None:
        for k, v in temps.items():
            self.lo[k] = v if k not in self.lo else min(self.lo[k], v)
            self.hi[k] = v if k not in self.hi else max(self.hi[k], v)
            if k in self.prev:
                self.delta[k] = v - self.prev[k]
            self.prev[k] = v
            self.hist.setdefault(k, collections.deque(maxlen=self.keep)).append(v)

    def arrow(self, k: str) -> str:
        """Blank until there is a second reading - never imply a trend from one."""
        d = self.delta.get(k)
        if d is None:
            return "  "
        # The XADC's last digit dithers by a few tenths with nothing happening.
        # Calling that a trend would make the display twitch and mean nothing.
        if d > 0.25:
            return "up"
        if d < -0.25:
            return "dn"
        return "--"


def render_live(temps: dict, tr: Track, colour: bool, started: float,
                n: int, extra: dict | None = None) -> str:
    out = []
    w = max(len(nm) for nm, _, _, _ in SENSORS)
    el = int(time.time() - started)
    out.append(f"  {time.strftime('%H:%M:%S')}   "
               f"{el // 60:02d}:{el % 60:02d} elapsed   {n} reading(s)")
    out.append("")
    # Built from the same field widths as the rows below, so the headings sit
    # over their columns instead of near them.
    out.append("  " + " " * w + "  " + f"{'now':>6}" + " " * 6 + f"{'min':>6}"
               + " " * 3 + f"{'max':>6}" + " " * 5 + f"{'state':<9}" + "  headroom")
    for name, limit, absmax, _src in SENSORS:
        t = temps[name]
        label, col = verdict(t, limit)
        c0, c1 = (col, "\033[0m") if colour else ("", "")
        head = max(0.0, limit - t)
        out.append(
            f"  {name:<{w}}  {t:6.1f} C {tr.arrow(name):>2}"
            f" {tr.lo[name]:6.1f} C {tr.hi[name]:6.1f} C"
            f"   {c0}{label:<9}{c1}"
            f"  {head:5.1f} C under {limit:.0f} C")
    # The graph. The table says where it is; this says how it got there, which
    # is the whole reason for watching rather than reading once.
    chars = _blocks()
    cols = shutil.get_terminal_size((100, 24)).columns
    # 2 indent + name + 2 gap + graph + 2 gap + "  nn.n - nn.n C"
    gw = max(10, min(tr.keep, cols - w - 24))
    graph = []
    for name, _limit, _absmax, _src in SENSORS:
        line, lo, hi = sparkline(tr.hist.get(name, ()), gw, chars)
        if not line:
            continue
        graph.append(f"  {name:<{w}}  {line:<{gw}}  {lo:5.1f} - {hi:5.1f} C")
    if graph:
        out.append("")
        out.extend(graph)
        if len(tr.hist.get(SENSORS[0][0], ())) < 2:
            out.append(f"  {'':<{w}}  (filling - one sample so far)")

    if extra:
        out.append("")
        for k, v in extra.items():
            if not k.startswith("_"):
                out.append(f"  {k}: {v}")
    return "\n".join(out)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog=__doc__.split("\n", 1)[1])
    p.add_argument("--uri", default=None,
                   help="libiio URI; by default the board is found by name")
    p.add_argument("--once", action="store_true",
                   help="a single reading instead of the live display")
    # Kept because devkit's help, the docs and muscle memory all still say it.
    # It now asks for what happens anyway, so it is a no-op rather than an error.
    p.add_argument("--watch", action="store_true",
                   help=argparse.SUPPRESS)
    p.add_argument("--live", action="store_true",
                   help="force the live display even when output is not a terminal")
    p.add_argument("--interval", type=float, default=2.0, metavar="S",
                   help="seconds between live readings (default 2)")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    args = p.parse_args(argv)

    host = args.uri.split(":", 1)[1] if args.uri else _board()
    if not host:
        print("cannot find the board - is it powered and on the network?",
              file=sys.stderr)
        return 2

    colour = sys.stdout.isatty() and not args.json
    try:
        with Iiod(host) as c:
            if args.json:
                t = read_temps(c)
                print(json.dumps({
                    "host": host,
                    "celsius": {k: round(v, 2) for k, v in t.items()},
                    "limits_celsius": {n: {"spec": lim, "absolute_max": am}
                                       for n, lim, am, _ in SENSORS},
                    "verdict": {n: verdict(t[n], lim)[0]
                                for n, lim, _, _ in SENSORS},
                }, indent=1))
                return 0

            # Live by default, because one number does not answer the question
            # people are actually asking. But an in-place display redirected to
            # a file is unreadable, so a non-tty falls back to one reading
            # unless --live says otherwise. --once always wins.
            # --watch predates this and meant "keep reading". It now asks for
            # the default, but it must still force live when piped, or a script
            # that used it would silently start getting a single reading.
            live = not args.once and (sys.stdout.isatty() or args.live or args.watch)

            if not live:
                temps = read_temps(c)
                extra = tx_state(c)
                extra["_limit_lines"] = tx_limit_lines(
                    extra.get("_tx_temp_limit_mC"), temps["AD9361"], host)
                print(f"die temperatures on {host}")
                print(render(temps, colour, extra))
                return 0

            # The provenance of the limits is printed once, above the live
            # region. Redrawing four lines of datasheet citation twice a second
            # would bury the thing being watched.
            print(f"die temperatures on {host}")
            first = read_temps(c)
            for name, limit, absmax, source in SENSORS:
                print(f"  {name}: warn at {limit:.0f} C"
                      + (f", absolute max {absmax:.0f} C" if absmax else ""))
                print(f"      {source}")
            print("\n  (Ctrl-C to stop)\n")

            tr = Track()
            started = time.time()
            n = 0
            prev_lines = 0
            temps = first
            while True:
                n += 1
                tr.update(temps)
                extra = tx_state(c)
                block = render_live(temps, tr, colour, started, n, extra)
                if prev_lines:
                    # Back up over the previous block and clear each line, so
                    # the display refreshes in place instead of scrolling.
                    sys.stdout.write(f"\033[{prev_lines}A")
                for line in block.split("\n"):
                    sys.stdout.write("\033[2K" + line + "\n")
                sys.stdout.flush()
                prev_lines = block.count("\n") + 1
                time.sleep(args.interval)
                temps = read_temps(c)
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        print(f"could not read the board at {host}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
