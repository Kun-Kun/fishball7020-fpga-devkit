#!/usr/bin/env python3
"""The one way a host-side tool in this repo may RAISE transmit output.

    from tx_gate import gated_set_atten, TxGateRefused, MUTE_DB

    gated_set_atten(0, -30.0)          # refused unless ch0 was affirmed
    gated_set_atten(0, MUTE_DB)        # quiet: always allowed, never gated

This is deliberately NOT a second gate. It shells out to `./devkit tx-guard
set-gain`, which pushes tools/tx-guard.sh to the board and runs it there, so
there is exactly one implementation of the affirmation rule, one store for the
affirmations (the board's /tmp, which is tmpfs, so a reboot withdraws them) and
one set of exit codes. An earlier attempt at this shipped a parallel gate beside
tx-guard.sh and it was the weaker of the two; see IDLE-CASES.md.

WHY A GATE AT ALL. This board has no directional coupler and no detector on
either transmit port, so whether an antenna is attached to TX cannot be measured
by any means. Nothing here detects anything. It requires a human to have said,
in a recorded and reboot-scoped way, that THAT port is terminated - which is the
only evidence that exists - and refuses to raise output otherwise.

WHAT IT DOES NOT DO. It is a tool-level gate, not enforcement. A program that
writes out_voltageN_hardwaregain itself walks straight past it, and the
affirmation is an ordinary file in world-writable tmpfs that any process can
forge. Read the LIMITS block at the top of tools/tx-guard.sh before trusting it
with anything. The enforcement that cannot be bypassed lives in the driver:
firmware/patches/0016's tx_disable latch.

QUIET IS NEVER GATED, and that is load-bearing. Muting must work when ssh is
down, when the affirmation is absent, and in a `finally:` block after something
has already gone wrong - so callers write MUTE_DB over their own connection and
do not come through here for it.
"""
from __future__ import annotations

import pathlib
import subprocess

MUTE_DB = -89.75                 # maximum attenuation on the AD9361
_STEP_TOL = 0.26                 # the attenuator quantises to 0.25 dB; allow one step
_SSH_TIMEOUT = 30.0              # see the note in _run()
_DEVKIT = pathlib.Path(__file__).resolve().parent.parent / "devkit"

# tools/tx-guard.sh's documented exit codes.
_OK, _REFUSED_VALIDATION, _NO_AFFIRMATION, _WRITE_FAILED = 0, 1, 3, 4
_UNREACHABLE = 4                 # ./devkit tx-guard's own "could not reach the board"


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    """Run the gate with a deadline, and turn a hang into a refusal.

    Bounded on purpose. These calls reach the board over ssh, and without a
    timeout a stalled connection blocks the caller indefinitely - which matters
    because a caller may already have a DMA buffer open, and a buffer enable is
    itself a raise. An unbounded wait there is an unbounded exposure window.
    A timeout is reported as a failure to reach the gate, never as permission.
    """
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=_SSH_TIMEOUT)
    except subprocess.TimeoutExpired as exc:
        raise TxGateError(
            f"the gate did not answer within {_SSH_TIMEOUT:g} s ({' '.join(cmd)}); "
            f"refusing to raise output") from exc


class TxGateError(RuntimeError):
    """The gate did not write the attenuation that was asked for."""


class TxGateRefused(TxGateError):
    """No affirmation on record for that channel. Raising was refused."""


def require_affirmation(channel: int, devkit: pathlib.Path | None = None) -> None:
    """Raise TxGateRefused unless that channel has an affirmation on record.

    For a tool that does its own attenuation writes - the selftest raises and
    lowers TX dozens of times during a ramp and a linearity sweep - asking the
    gate ONCE beats routing every write through set-gain over ssh. What the
    affirmation answers, whether that SMA port is terminated, does not change
    between writes. The trade is that this authorises the run rather than each
    write, so a tool using it must ask before its FIRST raise.
    """
    if channel not in (0, 1):
        raise ValueError(f"channel must be 0 (TX1A) or 1 (TX2A), not {channel!r}")
    cmd = [str(devkit or _DEVKIT), "tx-guard", "check", str(channel)]
    p = _run(cmd)
    if p.returncode == _OK:
        return
    out = (p.stdout + p.stderr).strip()
    if p.returncode == _NO_AFFIRMATION:
        raise TxGateRefused(
            f"REFUSED: this raises TX output on TX{channel + 1}A and no affirmation "
            f"that the port is terminated is on record.\n"
            f"    Look at the port. Then, only if it is into a load, an antenna you "
            f"may legally drive, or an attenuated loopback:\n"
            f"        ./devkit tx-guard affirm {channel}\n"
            f"    It dies at the next reboot. Channel 0 is TX1A, channel 1 is TX2A.")
    raise TxGateError(
        f"could not ask the gate whether channel {channel} is affirmed "
        f"(./devkit tx-guard exit {p.returncode}); refusing to raise output\n{out}")


def gated_set_atten(channel: int, db: float, devkit: pathlib.Path | None = None) -> float:
    """Ask the gate to write TX attenuation on one channel. Return the read-back.

    `channel` is 0 for TX1A or 1 for TX2A - two separate SMA ports, which is
    why one affirmation cannot stand for both. `db` is negative attenuation in
    dB, -89.75 quiet and 0 full output.

    Raises TxGateRefused when that channel has no affirmation on record, and
    TxGateError on a validation refusal, a failed write, or a board that cannot
    be reached. Every one of those leaves the port quiet or the failure loud;
    none of them silently proceeds.
    """
    if channel not in (0, 1):
        raise ValueError(f"channel must be 0 (TX1A) or 1 (TX2A), not {channel!r}")
    # Two decimals: the attenuator quantises to 0.25 dB, and tx-guard.sh
    # refuses anything that is not a plain decimal - "%g" would hand it
    # "-1e-05" for a value near zero.
    val = f"{db:.2f}"
    cmd = [str(devkit or _DEVKIT), "tx-guard", "set-gain", str(channel), val]
    p = _run(cmd)
    out = (p.stdout + p.stderr).strip()
    if p.returncode == _NO_AFFIRMATION:
        raise TxGateRefused(
            f"REFUSED: raising TX{channel + 1}A to {val} dB needs an affirmation that "
            f"that port is terminated, and none is on record.\n"
            f"    Look at the port. Then, only if it is into a load, an antenna you "
            f"may legally drive, or an attenuated loopback:\n"
            f"        ./devkit tx-guard affirm {channel}\n"
            f"    It dies at the next reboot. Channel 0 is TX1A, channel 1 is TX2A.\n"
            f"{out}")
    if p.returncode != _OK:
        raise TxGateError(
            f"the gate did not write {val} dB on channel {channel} "
            f"(./devkit tx-guard exit {p.returncode}); treat the port as suspect\n{out}")
    # tx-guard.sh reads the value back from sysfs and fails the write if it did
    # not land. Parse what it printed AND check it against what was asked for:
    # exit 0 plus a read-back line used to be accepted unconditionally, so a
    # value that had moved between the gate's compare and its report - the starve
    # watchdog firing in that gap puts it at maximum - came back as a success
    # carrying a number nobody had checked.
    for line in out.splitlines():
        if "attenuation verified at" in line:
            try:
                got = float(line.rsplit("at", 1)[1].split()[0])
            except (IndexError, ValueError) as exc:
                raise TxGateError(
                    f"could not parse the gate's read-back from {line!r}") from exc
            if abs(got - db) > _STEP_TOL:
                raise TxGateError(
                    f"the gate reported success at {got} dB but {val} dB was asked "
                    f"for on channel {channel}; treat the port as suspect\n{out}")
            return got
    raise TxGateError(f"the gate reported success without a read-back:\n{out}")
