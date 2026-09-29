#!/usr/bin/env python3
"""Transmit an arbitrary complex waveform from the Fishball7020, safely.

Uses the devkit's own stdlib IIOD client. The rules encoded here are the ones
that are expensive to rediscover:

  * TX attenuation is set AFTER the buffer starts and then READ BACK. Firmware
    patch 0005 restores a cached attenuation when a stream starts on a chip that
    looks muted, so anything written before OPEN is not what is on the air.
  * Channel numbering: on cf-ad9361-dds-core-lpc, voltage0/1 are TX1's I/Q and
    voltage2/3 are TX2's. On ad9361-phy the OUTPUT voltage0/voltage1 are the two
    transmit attenuators. Two different meanings for "channel 1".
  * Full scale is +-32767. The receive side is 12-bit (+-2047); mixing the two
    up is a 24.09 dB error.
  * stop() mutes first and closes the buffer second, then verifies. A cyclic
    buffer keeps playing after the process that created it exits, so closing
    without muting can leave the transmitter live.
  * RAISING attenuation goes through the transmit gate (tools/tx_gate.py, which
    runs tools/tx-guard.sh on the board) and is REFUSED unless a human has
    recorded that THAT port is terminated:

        ./devkit tx-guard affirm 0      # TX1A        affirm 1   # TX2A

    Channel 0 is TX1A and channel 1 is TX2A, two separate SMA ports, so one
    affirmation does not stand for both. It expires at the next reboot. Nothing
    here detects an antenna, because this board has no coupler and no detector on
    the transmit port - a human's word is the only evidence there is.
    Muting is never gated: it has to work when ssh is down.
"""
import sys, math, pathlib
import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "selftest"))
from iiod_min import Iiod, mask_for                                    # noqa: E402
import sys as _s, pathlib as _pl                     # noqa: E402
_s.path.insert(0, str(_pl.Path(__file__).resolve().parent.parent))
from board_addr import resolve as _board             # name first, USB last
from tx_gate import (gated_set_atten, require_affirmation,   # the only way to RAISE
                     assert_quiet_after_enable, MUTE_DB)

PHY, TX, RX = "ad9361-phy", "cf-ad9361-dds-core-lpc", "cf-ad9361-lpc"
TX_LO = "altvoltage1"
MUTE = -89.75
FULLSCALE = 32767


class Board:
    def __init__(self, host):
        self.c = Iiod(host=host); self.c.connect()
        self.dev = self.c.devices()          # {name: (device_id, n_scan_channels)}
        for need in (PHY, TX):
            if need not in self.dev:
                raise SystemExit(f"device {need} not found on {host}")

    # attributes --------------------------------------------------------------
    def rd(self, dev, ch, attr, out=False):
        return self.c.read(self.dev[dev][0], ch, attr, output=out)

    def wr(self, dev, ch, attr, val, out=False):
        return self.c.write(self.dev[dev][0], ch, attr, str(val), output=out)

    # setup -------------------------------------------------------------------
    def configure_tx(self, lo_hz, fs, bw=None):
        # mute() returns False when a channel did not read back muted. Acting on that
        # is the point of the return value: this call is about to power the TX LO up,
        # so an unproven mute has to stop the run, not just print.
        if not self.mute():
            raise RuntimeError("refusing to configure TX: a channel would not mute")
        self.wr(PHY, "voltage0", "sampling_frequency", int(fs))
        self.wr(PHY, "voltage0", "rf_bandwidth", int(bw or fs * 0.8))
        self.wr(PHY, TX_LO, "frequency", int(lo_hz), out=True)
        self.wr(PHY, TX_LO, "powerdown", 0, out=True)
        return dict(fs=float(self.rd(PHY, "voltage0", "sampling_frequency")),
                    bw=float(self.rd(PHY, "voltage0", "rf_bandwidth")),
                    lo=float(self.rd(PHY, TX_LO, "frequency", out=True)))

    def mute(self):
        """Mute both channels, and say so if it did not land.

        stop() depends on this and every refusal path calls stop(), so a silent
        failure here is a silently live port. It used to swallow everything.
        """
        ok = True
        for v in ("voltage0", "voltage1"):
            try:
                self.wr(PHY, v, "hardwaregain", MUTE, out=True)
                got = float(self.rd(PHY, v, "hardwaregain", out=True).split()[0])
                if got > MUTE + 0.26:
                    print(f"*** MUTE DID NOT LAND on {v}: reads {got} dB - TREAT THAT "
                          f"PORT AS LIVE ***", file=sys.stderr)
                    ok = False
            except Exception as exc:                      # noqa: BLE001
                print(f"*** MUTE FAILED on {v} ({exc}) - TREAT THAT PORT AS LIVE ***",
                      file=sys.stderr)
                ok = False
        return ok

    # transmit ----------------------------------------------------------------
    def transmit(self, iq, atten_db, pair=0, cyclic=True, scale=1.0):
        """Start a cyclic buffer, then set and verify the attenuation."""
        if np.abs(iq).max() > 1.0 + 1e-9:
            raise ValueError("iq must be normalised to |x| <= 1 before scaling")
        s = (iq * scale * FULLSCALE)
        i = np.clip(np.round(s.real), -FULLSCALE, FULLSCALE).astype(np.int16)
        q = np.clip(np.round(s.imag), -FULLSCALE, FULLSCALE).astype(np.int16)
        values = np.empty(2 * len(iq), dtype=np.int16)
        values[0::2], values[1::2] = i, q

        did, total = self.dev[TX]
        # BEFORE the buffer. Opening a TX DMA buffer raises output on its own -
        # the preenable hook powers the LO up and restores the last stream's
        # cached attenuation, measured at -61.5 dB from a muted board - so the
        # gate has to answer before write_samples, not after it.
        if atten_db > MUTE_DB:
            try:
                require_affirmation(pair)
            except Exception:
                # stop() here too, not only on the later failure paths: configure_tx
                # has already powered the TX LO up, and leaving it up on the way out
                # of a refusal relies on the caller having a finally: clause.
                self.stop()
                raise
        # mute before close; the stop hook caches whatever it finds. Checked, because
        # the next two lines open a buffer and the kernel unmutes on the enable.
        if not self.mute():
            raise RuntimeError("refusing to open a TX buffer: a channel would not mute")
        self.c.close_buffer(did)
        first = pair * 2
        self.c.write_samples(did, values.tolist(),
                             mask_for([first, first + 1], total),
                             nchannels=2, cyclic=cyclic)
        # The enable just happened. Even when this call is not raising anything, it
        # can have raised an attenuator via the kernel's cache restore, so check
        # before doing anything else.
        try:
            assert_quiet_after_enable(
                lambda ch: float(self.rd(PHY, f"voltage{ch}", "hardwaregain", out=True).split()[0]),
                "transmit buffer enable")
        except Exception:
            self.stop()
            raise
        # AFTER the buffer: patch 0005 would otherwise restore a cached value.
        v = f"voltage{pair}"
        if atten_db > MUTE_DB:
            # Through the gate, which refuses without an affirmation for THIS
            # channel and reads the value back on the board itself. A refusal
            # propagates: the caller does not get a quietly muted transmitter
            # while believing it asked for output. stop() first, so a refused
            # raise does not leave a stream running.
            try:
                gated_set_atten(pair, atten_db)
            except Exception:
                self.stop()
                raise
        else:
            self.wr(PHY, v, "hardwaregain", round(atten_db, 2), out=True)
        # Verified again over THIS connection, not the gate's. The gate reaches
        # the board over ssh and this class over IIOD; a read-back here is what
        # catches the two ever resolving to different boards.
        got = float(self.rd(PHY, v, "hardwaregain", out=True).split()[0])
        if abs(got - atten_db) > 0.3:
            self.stop()
            raise RuntimeError(f"attenuation read back {got} dB, asked {atten_db} dB")
        return got

    def stop(self):
        """Mute first, then close. Order matters.

        Called from exception handlers, so this never raises - masking the refusal
        that brought us here would be worse. It reports instead: the returned dict
        carries `muted`, and anything that did not land has already gone to stderr.
        """
        ok = self.mute()
        self.c.close_buffer(self.dev[TX][0])
        # The second mute is the one that counts: closing the buffer runs the kernel's
        # stop hook, which caches whatever attenuation it finds for the next enable.
        ok = self.mute() and ok
        try:
            self.wr(PHY, TX_LO, "powerdown", 1, out=True)
            lo_down = self.rd(PHY, TX_LO, "powerdown", out=True).strip() == "1"
        except Exception as exc:                          # noqa: BLE001
            print(f"*** TX LO POWERDOWN FAILED ({exc}) - the synthesiser is still "
                  f"running; the channels are muted but the chain is not cold ***",
                  file=sys.stderr)
            lo_down = False
        else:
            if not lo_down:
                print("*** TX LO POWERDOWN DID NOT LAND - the synthesiser is still "
                      "running ***", file=sys.stderr)
        out = {v: self.rd(PHY, v, "hardwaregain", out=True) for v in ("voltage0", "voltage1")}
        out["muted"] = ok
        out["lo_down"] = lo_down
        return out

    def close(self):
        self.c.close()


if __name__ == "__main__":
    import os
    b = Board(sys.argv[1] if len(sys.argv) > 1 else _board())
    print("devices:", {k: v for k, v in b.dev.items()})
    print("TX atten:", b.rd(PHY, "voltage0", "hardwaregain", out=True),
          "/", b.rd(PHY, "voltage1", "hardwaregain", out=True))
    print("TX LO:", b.rd(PHY, TX_LO, "frequency", out=True),
          "powerdown:", b.rd(PHY, TX_LO, "powerdown", out=True))
    print("fs:", b.rd(PHY, "voltage0", "sampling_frequency"))
    b.close()
