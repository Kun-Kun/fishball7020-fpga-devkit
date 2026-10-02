"""Mode S message decoding: the checksum, the fields, and an aircraft table.

Mode S is the 1090 MHz reply format secondary radar uses; ADS-B (Automatic
Dependent Surveillance - Broadcast) is the part of it an aircraft sends on its
own, twice a second, without being asked: its identity, position, altitude and
velocity. Every message starts with a 5-bit downlink format (DF) that says
what kind it is and how long: 56 bits for DF0-15, 112 bits for DF16 and up.

Pure Python, no numpy, no radio: the demodulator in demod.py turns samples into
bytes, and this file turns bytes into meaning.

The checksum is not the same kind of thing in every format, and treating it as
one is the usual way a decoder ends up full of ghosts:

  DF17, DF18   ADS-B. The 24-bit parity is a plain CRC: remainder 0 means intact.
  DF11         all-call reply. The remainder may carry a 7-bit interrogator id
               (IID) in its low bits, so "low 7 bits only" is intact.
  DF0/4/5/16/  replies to a radar. The parity is the CRC XOR the aircraft's
  20/21/24     address (AP), so the remainder IS the address. It is only
               trustworthy when that address was already heard in a DF11/17/18.
"""

import math
import time

# ---- CRC -------------------------------------------------------------------

GENERATOR = 0xFFF409           # the 24 low bits of the 25-bit generator 0x1FFF409

_TABLE = []
for _i in range(256):
    _c = _i << 16
    for _ in range(8):
        _c = ((_c << 1) ^ GENERATOR) if _c & 0x800000 else (_c << 1)
    _TABLE.append(_c & 0xFFFFFF)


def crc24(data):
    """The CRC of `data` (bytes), as Mode S computes it."""
    crc = 0
    for b in data:
        crc = ((crc << 8) & 0xFFFFFF) ^ _TABLE[((crc >> 16) ^ b) & 0xFF]
    return crc


def syndrome(msg):
    """CRC of everything but the last 3 bytes, XOR those 3 bytes. 0 = intact."""
    return crc24(msg[:-3]) ^ int.from_bytes(msg[-3:], "big")


def _single_bit_syndromes(nbytes):
    """syndrome -> bit index, for every single-bit error after the DF field."""
    out = {}
    for bit in range(5, nbytes * 8):
        e = bytearray(nbytes)
        e[bit // 8] = 0x80 >> (bit % 8)
        out[syndrome(bytes(e))] = bit
    return out


_FIX112 = _single_bit_syndromes(14)


def frame_length(df):
    """Bits in a message of downlink format df."""
    return 112 if df >= 16 else 56


VALID_DF = {0, 4, 5, 11, 16, 17, 18, 20, 21, 24}


def df_of(msg):
    df = msg[0] >> 3
    return 24 if df >= 24 else df          # DF24 uses only its top 2 bits


def check(msg, known=()):
    """How far to trust a message.

    Returns (status, icao, corrected_msg). status is one of
      "ok"      the parity proves the message intact
      "fixed"   one bad bit, repaired (DF17/18 only)
      "addr"    address/parity matched an aircraft already heard
      None      not trustworthy: drop it
    """
    df = df_of(msg)
    if df not in VALID_DF or len(msg) * 8 != frame_length(df):
        return None, None, msg
    syn = syndrome(msg)
    if df in (17, 18):
        if syn == 0:
            return "ok", int.from_bytes(msg[1:4], "big"), msg
        bit = _FIX112.get(syn)
        if bit is not None:
            fixed = bytearray(msg)
            fixed[bit // 8] ^= 0x80 >> (bit % 8)
            return "fixed", int.from_bytes(fixed[1:4], "big"), bytes(fixed)
        return None, None, msg
    if df == 11:
        if syn & ~0x7F == 0:
            return "ok", int.from_bytes(msg[1:4], "big"), msg
        return None, None, msg
    if syn in known:
        return "addr", syn, msg
    return None, None, msg


# ---- field decoding --------------------------------------------------------

_CHARS = "#ABCDEFGHIJKLMNOPQRSTUVWXYZ##### ###############0123456789######"


def _bits(value, total, start, length):
    """`length` bits of a `total`-bit integer, `start` counted from the MSB."""
    return (value >> (total - start - length)) & ((1 << length) - 1)


def altitude_ac12(ac):
    """The 12-bit altitude of an airborne position (DF17 TC 9-18), in feet."""
    if ac == 0:
        return None
    if ac & 0x010:                                   # Q bit: 25 ft steps
        n = ((ac & 0xFE0) >> 1) | (ac & 0x00F)
        return n * 25 - 1000
    return _gillham(((ac & 0xFC0) << 1) | (ac & 0x03F))


def altitude_ac13(ac):
    """The 13-bit altitude of DF0/4/16/20, in feet."""
    if ac == 0:
        return None
    if ac & 0x0040:                                  # M bit: metres
        n = ((ac & 0x1F80) >> 1) | (ac & 0x003F)
        return int(n * 3.28084)
    if ac & 0x0010:                                  # Q bit: 25 ft steps
        n = ((ac & 0x1F80) >> 2) | ((ac & 0x0020) >> 1) | (ac & 0x000F)
        return n * 25 - 1000
    return _gillham(ac)


def _gillham(ac13):
    """Gray-coded (Gillham) altitude in 100 ft steps; None when invalid.

    Only aircraft with old encoders send it, but they are still flying."""
    c1, a1, c2, a2, c4, a4, _m, b1, _q, b2, d2, b4, d4 = (
        (ac13 >> (12 - i)) & 1 for i in range(13))
    n500 = _gray((d2 << 7) | (d4 << 6) | (a1 << 5) | (a2 << 4) | (a4 << 3)
                 | (b1 << 2) | (b2 << 1) | b4)
    n100 = _gray((c1 << 2) | (c2 << 1) | c4)
    if n100 in (0, 5, 6):
        return None
    if n100 == 7:
        n100 = 5
    if n500 % 2:
        n100 = 6 - n100
    return n500 * 500 + n100 * 100 - 1300


def _gray(g):
    n = 0
    while g:
        n ^= g
        g >>= 1
    return n


def squawk(id13):
    """The four-digit transponder code of DF5/21."""
    c1, a1, c2, a2, c4, a4, _x, b1, d1, b2, d2, b4, d4 = (
        (id13 >> (12 - i)) & 1 for i in range(13))
    a = (a4 << 2) | (a2 << 1) | a1
    b = (b4 << 2) | (b2 << 1) | b1
    c = (c4 << 2) | (c2 << 1) | c1
    d = (d4 << 2) | (d2 << 1) | d1
    return f"{a}{b}{c}{d}"


def callsign(me):
    return "".join(_CHARS[_bits(me, 56, 8 + 6 * i, 6)] for i in range(8)) \
        .replace("#", "").strip()


def velocity(me):
    """(ground speed or airspeed kt, track or heading deg, vertical rate fpm, kind)."""
    st = _bits(me, 56, 5, 3)
    vr_raw = _bits(me, 56, 37, 9)
    vrate = None if vr_raw == 0 else (vr_raw - 1) * 64 * (-1 if _bits(me, 56, 36, 1) else 1)
    if st in (1, 2):
        vew, vns = _bits(me, 56, 14, 10), _bits(me, 56, 25, 10)
        if vew == 0 or vns == 0:
            return None, None, vrate, "GS"
        scale = 4 if st == 2 else 1
        vx = (vew - 1) * scale * (-1 if _bits(me, 56, 13, 1) else 1)   # + east
        vy = (vns - 1) * scale * (-1 if _bits(me, 56, 24, 1) else 1)   # + north
        speed = math.hypot(vx, vy)
        track = math.degrees(math.atan2(vx, vy)) % 360
        return round(speed), round(track, 1), vrate, "GS"
    if st in (3, 4):
        hdg = _bits(me, 56, 14, 10) * 360 / 1024 if _bits(me, 56, 13, 1) else None
        asp = _bits(me, 56, 25, 10)
        speed = None if asp == 0 else (asp - 1) * (4 if st == 4 else 1)
        kind = "TAS" if _bits(me, 56, 24, 1) else "IAS"
        return speed, None if hdg is None else round(hdg, 1), vrate, kind
    return None, None, vrate, None


# ---- CPR position ----------------------------------------------------------
# Compact Position Reporting: each position message carries only the low 17
# bits of latitude and longitude within a zone, alternating between two zone
# grids ("even" and "odd"). One even and one odd message a few seconds apart
# pin the position globally; after that each message decodes alone, relative
# to the last position (a "local" decode).

NZ = 15


def nl(lat):
    """Number of longitude zones at a latitude."""
    if lat == 0:
        return 59
    if abs(lat) == 87:
        return 2
    if abs(lat) > 87:
        return 1
    a = 1 - math.cos(math.pi / (2 * NZ))
    b = math.cos(math.pi / 180 * abs(lat)) ** 2
    return int(math.floor(2 * math.pi / math.acos(1 - a / b)))


def cpr_global(even, odd, latest_odd):
    """Position from an (lat_cpr, lon_cpr) even/odd pair, both as 17-bit ints."""
    lat0, lon0 = even[0] / 131072, even[1] / 131072
    lat1, lon1 = odd[0] / 131072, odd[1] / 131072
    j = math.floor(59 * lat0 - 60 * lat1 + 0.5)
    rlat0 = 360 / 60 * (j % 60 + lat0)
    rlat1 = 360 / 59 * (j % 59 + lat1)
    if rlat0 >= 270:
        rlat0 -= 360
    if rlat1 >= 270:
        rlat1 -= 360
    if nl(rlat0) != nl(rlat1):
        return None                       # the pair straddles a zone boundary
    if latest_odd:
        lat, ni = rlat1, max(nl(rlat1) - 1, 1)
        m = math.floor(lon0 * (nl(rlat1) - 1) - lon1 * nl(rlat1) + 0.5)
        lon = 360 / ni * (m % ni + lon1)
    else:
        lat, ni = rlat0, max(nl(rlat0), 1)
        m = math.floor(lon0 * (nl(rlat0) - 1) - lon1 * nl(rlat0) + 0.5)
        lon = 360 / ni * (m % ni + lon0)
    if lon >= 180:
        lon -= 360
    return lat, lon


def cpr_local(cpr, odd, ref_lat, ref_lon):
    """Position from one message, given a reference within ~180 NM of it."""
    lat_c, lon_c = cpr[0] / 131072, cpr[1] / 131072
    dlat = 360 / (4 * NZ - (1 if odd else 0))
    j = math.floor(ref_lat / dlat) + math.floor(0.5 + (ref_lat % dlat) / dlat - lat_c)
    lat = dlat * (j + lat_c)
    dlon = 360 / max(nl(lat) - (1 if odd else 0), 1)
    m = math.floor(ref_lon / dlon) + math.floor(0.5 + (ref_lon % dlon) / dlon - lon_c)
    lon = dlon * (m + lon_c)
    return lat, lon


# ---- one message -----------------------------------------------------------

def decode(msg):
    """Fields of one message (already checked) as a dict. Never raises."""
    df = df_of(msg)
    out = {"df": df}
    n = len(msg) * 8
    val = int.from_bytes(msg, "big")
    if df in (0, 4, 16, 20):
        out["altitude"] = altitude_ac13(_bits(val, n, 19, 13))
    if df in (5, 21):
        out["squawk"] = squawk(_bits(val, n, 19, 13))
    if df in (17, 18):
        me = int.from_bytes(msg[4:11], "big")
        tc = me >> 51
        out["tc"] = tc
        if 1 <= tc <= 4:
            out["kind"] = "ident"
            out["callsign"] = callsign(me)
        elif 5 <= tc <= 8:
            out["kind"] = "surface"
        elif 9 <= tc <= 18 or 20 <= tc <= 22:
            out["kind"] = "position"
            ac = _bits(me, 56, 8, 12)
            if tc <= 18:
                out["altitude"] = altitude_ac12(ac)
            elif ac:
                out["altitude"] = round(ac * 3.28084)     # GNSS height, metres
            out["odd"] = bool(_bits(me, 56, 21, 1))
            out["cpr"] = (_bits(me, 56, 22, 17), _bits(me, 56, 39, 17))
        elif tc == 19:
            out["kind"] = "velocity"
            spd, trk, vr, k = velocity(me)
            out.update(speed=spd, track=trk, vrate=vr, speed_kind=k)
        elif tc == 28:
            out["kind"] = "status"
        elif tc == 29:
            out["kind"] = "target"
        elif tc == 31:
            out["kind"] = "opstatus"
        else:
            out["kind"] = f"tc{tc}"
    return out


DF_NAMES = {0: "short ACAS", 4: "altitude", 5: "identity", 11: "all-call",
            16: "long ACAS", 17: "ADS-B", 18: "TIS-B/ADS-R", 20: "Comm-B alt",
            21: "Comm-B id", 24: "Comm-D"}


def summary(d):
    """One line of what a decoded message says."""
    parts = [DF_NAMES.get(d["df"], f"DF{d['df']}")]
    if "kind" in d:
        parts.append(d["kind"])
    for key, fmt in (("callsign", "{}"), ("squawk", "sq {}"), ("altitude", "{} ft"),
                     ("speed", "{} kt"), ("track", "{}°"), ("vrate", "{:+} fpm")):
        if d.get(key) is not None:
            parts.append(fmt.format(d[key]))
    if "cpr" in d:
        parts.append("odd" if d["odd"] else "even")
    return "  ".join(parts)


# ---- the aircraft table ----------------------------------------------------

class Aircraft:
    __slots__ = ("icao", "callsign", "squawk", "altitude", "speed", "speed_kind",
                 "track", "vrate", "lat", "lon", "messages", "first_seen",
                 "last_seen", "rssi", "_even", "_odd", "_pos_time")

    def __init__(self, icao, now):
        self.icao = icao
        self.callsign = self.squawk = self.altitude = None
        self.speed = self.speed_kind = self.track = self.vrate = None
        self.lat = self.lon = None
        self.messages = 0
        self.first_seen = self.last_seen = now
        self.rssi = None
        self._even = self._odd = None        # (cpr, time)
        self._pos_time = None


class Tracker:
    """Folds checked messages into one row per aircraft.

    ref is an optional (lat, lon) of the receiver; with it a single position
    message decodes without waiting for an even/odd pair."""

    PAIR_WINDOW = 10.0          # seconds an even/odd pair may be apart
    ADDR_MEMORY = 60.0          # seconds an address stays "known" for AP checks

    def __init__(self, ref=None, expire=60.0):
        self.ref = ref
        self.expire = expire
        self.aircraft = {}
        self.known = {}             # icao -> last time heard with a real CRC
        self.stats = {"frames": 0, "ok": 0, "fixed": 0, "addr": 0, "dropped": 0}

    def known_addresses(self, now):
        return {a for a, t in self.known.items() if now - t < self.ADDR_MEMORY}

    def feed(self, msg, now=None, rssi=None):
        """Check, decode and fold in one message. Returns (status, icao, fields)
        or None when the message is not trustworthy."""
        now = time.time() if now is None else now
        self.stats["frames"] += 1
        status, icao, msg = check(msg, self.known_addresses(now))
        if status is None:
            self.stats["dropped"] += 1
            return None
        self.stats[status] += 1
        if status in ("ok", "fixed"):
            self.known[icao] = now
        d = decode(msg)
        d["hex"] = msg.hex().upper()
        ac = self.aircraft.get(icao)
        if ac is None:
            ac = self.aircraft[icao] = Aircraft(icao, now)
        ac.messages += 1
        ac.last_seen = now
        if rssi is not None:
            ac.rssi = rssi if ac.rssi is None else 0.7 * ac.rssi + 0.3 * rssi
        for key in ("callsign", "squawk", "altitude", "speed", "speed_kind",
                    "track", "vrate"):
            if d.get(key) is not None:
                setattr(ac, key, d[key])
        if "cpr" in d:
            self._position(ac, d, now)
        return status, icao, d

    def _position(self, ac, d, now):
        odd, cpr = d["odd"], d["cpr"]
        if odd:
            ac._odd = (cpr, now)
        else:
            ac._even = (cpr, now)
        pos = None
        if ac.lat is not None and now - ac._pos_time < self.PAIR_WINDOW * 3:
            pos = cpr_local(cpr, odd, ac.lat, ac.lon)
        elif ac._even and ac._odd and abs(ac._even[1] - ac._odd[1]) < self.PAIR_WINDOW:
            pos = cpr_global(ac._even[0], ac._odd[0], odd)
        elif self.ref is not None:
            pos = cpr_local(cpr, odd, *self.ref)
        if pos is not None:
            d["lat"], d["lon"] = round(pos[0], 5), round(pos[1], 5)
            ac.lat, ac.lon, ac._pos_time = pos[0], pos[1], now

    def prune(self, now=None):
        now = time.time() if now is None else now
        for icao in [i for i, a in self.aircraft.items() if now - a.last_seen > self.expire]:
            del self.aircraft[icao]
        for icao in [i for i, t in self.known.items() if now - t > self.ADDR_MEMORY]:
            del self.known[icao]
