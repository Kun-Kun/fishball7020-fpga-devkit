#!/usr/bin/env python3
"""Execute the transmitter-safety behaviours. No board, no network, no radio.

WHY THIS FILE EXISTS. Review rounds 7 and 8 each found more HIGH defects than rounds
4, 5 and 6 combined, and three of round 8's were introduced by round 7's own fixes.
Every one of those was behavioural, and every one would have been caught by RUNNING the
changed branch once:

  - a trap list widened to HUP PIPE QUIT with no `exit`, so the handler ran and the
    script CARRIED ON into the next case and re-raised the transmitter;
  - `rep.add(...)` called with three positionals against `add(group, name, verdict,
    detail)`, so the FAIL that exists to stop a HEALTHY verdict never counted;
  - `mute_both()` returning None, so no caller could act on a failed mute.

The fixes were checked with `sh -n` and `py_compile`, which prove a file parses and
nothing else. So: this file asserts on OBSERVED BEHAVIOUR. Every check here runs the
thing. Nothing greps for a string, because a string is what was right in all three
cases above while the behaviour was wrong.

    python3 tools/selftest/test_safety.py

Exit 0 if every behaviour holds, 1 otherwise. Runs in Host-tools CI.
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
CASES = ROOT / "tools" / "tx-idle-cases"
FAILURES = []          # names of behaviours that did not hold
CHECKS = 0


def check(name, ok, detail=""):
    global CHECKS
    CHECKS += 1
    if ok:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}" + (f"\n        {detail}" if detail else ""))
        FAILURES.append(name)


def sh(script_text, signal=None, delay=1.5):
    """Run a /bin/sh script, optionally signalling it, and return (exit, stdout)."""
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
        f.write(script_text)
        path = f.name
    try:
        p = subprocess.Popen(["/bin/sh", path], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True)
        if signal:
            import time
            time.sleep(delay)
            p.send_signal(signal)
        out, _ = p.communicate(timeout=30)
        return p.returncode, out
    finally:
        os.unlink(path)


# --------------------------------------------------------------------------------
# 1. A trapped signal must TERMINATE the script, not merely run the handler.
#
# This is round 7's regression, reduced to its mechanism. The trap lines are read out
# of each real harness so the test tracks the scripts rather than a copy of them.
# --------------------------------------------------------------------------------
def trap_lines(path):
    """The script's own trap lines, and the handler name they install."""
    text = path.read_text()
    lines = [l for l in text.splitlines() if re.match(r"^trap\s", l)]
    m = re.search(r"^trap ['\"]?(\w+)", lines[0]) if lines else None
    return lines, (m.group(1) if m else None)


import signal as S

for script in ("cases123.sh", "case5.sh", "case4b.sh", "dds-tone.sh", "case4a.sh"):
    p = CASES / script
    if not p.is_file():
        check(f"{script}: present", False, "file missing")
        continue
    lines, handler = trap_lines(p)
    if not lines or not handler:
        check(f"{script}: installs a trap", False, "no trap line found")
        continue

    # Rebuild the script's exact trap structure around a stub handler and RUN it.
    stub = "\n".join([
        f"{handler}() {{ trap '' INT TERM HUP PIPE QUIT 2>/dev/null; echo HANDLER; }}",
        *lines,
        "i=0; while [ $i -lt 6 ]; do i=$((i+1)); echo tick; sleep 1; done",
        "echo REACHED-THE-END",
    ])
    for sig, want in ((S.SIGTERM, 143), (S.SIGHUP, 143), (S.SIGINT, 130)):
        rc, out = sh(stub, signal=sig)
        ran = out.count("HANDLER")
        went_on = "REACHED-THE-END" in out
        check(f"{script}: {sig.name} runs the handler once and EXITS",
              ran == 1 and not went_on and rc == want,
              f"handler ran {ran}x, reached-end={went_on}, exit={rc} (want {want})")

# The control: the shape round 7 shipped must be demonstrably broken, so this test
# would actually have caught it. If this "fails", the mechanism no longer exists and
# the checks above prove nothing.
rc, out = sh("h() { echo HANDLER; }\ntrap 'h' EXIT INT TERM HUP PIPE QUIT\n"
             "i=0; while [ $i -lt 4 ]; do i=$((i+1)); sleep 1; done\necho REACHED-THE-END",
             signal=S.SIGHUP)
check("control: a trap WITHOUT exit does let the script continue",
      "REACHED-THE-END" in out,
      "the regression mechanism is gone; the trap checks above no longer test anything")


# --------------------------------------------------------------------------------
# 2. A failed mute must reach the REPORT, not only stderr.
#
# Round 7 added the row with the wrong arity, so counts[FAIL] stayed 0 and the run
# printed HEALTHY. Assert on the count, which is what the verdict is computed from.
# --------------------------------------------------------------------------------
sys.path.insert(0, str(ROOT / "tools" / "selftest"))
import importlib.util

spec = importlib.util.spec_from_file_location("st", ROOT / "tools" / "selftest" / "sdr_selftest.py")
st = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(st)
except SystemExit:
    pass

rep = st.Report()
rep.add("Digital interface (BIST)", "transmitter mutes on command", st.FAIL, "port may be live")
counts = rep.counts()
check("a FAIL row increments counts[FAIL] (the verdict is computed from it)",
      counts.get(st.FAIL, 0) == 1,
      f"counts={dict((k, v) for k, v in counts.items() if v)}")

rep2 = st.Report()
rep2.add("g", "transmitter mutes on command", st.PASS, "both read back muted")
check("a PASS row increments counts[PASS]", rep2.counts().get(st.PASS, 0) == 1)


# --------------------------------------------------------------------------------
# 3. Every transmitting script must REFUSE without an explicit channel.
#
# Run them. A usage string that exits 0 is the defect; so is one that reaches sysfs.
# --------------------------------------------------------------------------------
# Exit status ALONE is not enough: on a host with no /sys these scripts exit 1 for a
# later reason too, so a reintroduced default would pass. Require the refusal message,
# which only the channel check emits. (Found by re-introducing the defect and watching
# an earlier version of this test pass anyway.)
for script, args in (("cases123.sh", []), ("case5.sh", []), ("case4b.sh", []),
                     ("case4-poller.sh", []), ("cases123.sh", ["2"]),
                     ("case5.sh", ["both"]), ("case4b.sh", [""])):
    p = CASES / script
    r = subprocess.run(["/bin/sh", str(p), *args], capture_output=True, text=True, timeout=30)
    out = r.stdout + r.stderr
    refused = r.returncode == 1 and ("usage:" in out.lower() or "no default" in out.lower()
                                     or "name the port" in out.lower())
    check(f"{script} {args or '(no channel)'}: refuses, naming the missing channel",
          refused, f"exit={r.returncode} out={out.strip()[:100]!r}")

r = subprocess.run([sys.executable, str(CASES / "tone.py"), "-55", "8"],
                   capture_output=True, text=True, timeout=60, cwd=ROOT)
check("tone.py without a channel: refuses with exit 1", r.returncode == 1,
      f"exit={r.returncode}")

r = subprocess.run(["/bin/bash", str(CASES / "case4a.sh"), "/tmp", "3071997", "34341", "t"],
                   capture_output=True, text=True, timeout=30, cwd=ROOT)
check("case4a.sh without a channel: refuses with exit 1", r.returncode == 1,
      f"exit={r.returncode}")


# --------------------------------------------------------------------------------
# 4. dds-tone.sh must not ENERGISE on an unrecognised action.
#
# Anything that was not exactly "off" used to fall through to the energise branch.
# These run on a host with no /sys, so reaching the energise branch shows up as an
# exit status that is neither the validation's 1 nor the gate's 4.
# --------------------------------------------------------------------------------
for act in ("OFF", "Off", "stop", "0", "off ", "ON", "xyz"):
    r = subprocess.run(["/bin/sh", str(CASES / "dds-tone.sh"), "1", act],
                       capture_output=True, text=True, timeout=30)
    check(f"dds-tone.sh 1 {act!r}: rejected, does not energise",
          r.returncode == 1 and "must be exactly" in (r.stdout + r.stderr),
          f"exit={r.returncode} out={(r.stdout + r.stderr).strip()[:90]!r}")


# --------------------------------------------------------------------------------
# 5. The gate must fail CLOSED on an unreadable attenuator.
#
# "Unknown" must resolve toward the hazard, not toward quiet.
# --------------------------------------------------------------------------------
sys.path.insert(0, str(ROOT / "tools"))
spec = importlib.util.spec_from_file_location("tx_gate", ROOT / "tools" / "tx_gate.py")
tg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tg)

for label, reader in (("raises", lambda ch: (_ for _ in ()).throw(OSError("no board"))),
                      ("returns None", lambda ch: None)):
    try:
        tg.assert_quiet_after_enable(reader, "unit test")
        check(f"assert_quiet_after_enable fails closed when the read {label}", False,
              "it returned instead of raising")
    except Exception:
        check(f"assert_quiet_after_enable fails closed when the read {label}", True)

try:
    tg.assert_quiet_after_enable(lambda ch: -30.0, "unit test")
    check("assert_quiet_after_enable rejects a raised attenuator", False, "it returned")
except Exception:
    check("assert_quiet_after_enable rejects a raised attenuator", True)

try:
    tg.assert_quiet_after_enable(lambda ch: tg.MUTE_DB, "unit test")
    check("assert_quiet_after_enable accepts a muted board", True)
except Exception as exc:
    check("assert_quiet_after_enable accepts a muted board", False, str(exc))


# --------------------------------------------------------------------------------
# 5b. The gate without bash (Windows): tx_gate.py's own ssh route.
#
# It must push the same tx-guard.sh, return its exit codes unchanged, and turn an
# unreachable board into exit 4 - never into permission. A stand-in paramiko
# plays the board: it records commands and answers with a scripted exit code.
# --------------------------------------------------------------------------------
import types


class _Stream:
    def __init__(self, data=b"", rc=0):
        self._data, self.channel = data, types.SimpleNamespace(
            recv_exit_status=lambda: rc, shutdown_write=lambda: None)
        self.written = b""
    def read(self):
        return self._data
    def write(self, b):
        self.written += b


class _FakeClient:
    log, answer, refuse_connect = [], (0, b"", b""), False
    def set_missing_host_key_policy(self, _):
        pass
    def connect(self, host, **kw):
        if _FakeClient.refuse_connect:
            raise OSError("timed out")
    def exec_command(self, cmd, timeout=None):
        _FakeClient.log.append(cmd)
        rc, out, err = (0, b"", b"") if cmd.startswith("cat >") else _FakeClient.answer
        stdin = _Stream()
        return stdin, _Stream(out, rc), _Stream(err, rc)
    def close(self):
        pass


sys.modules["paramiko"] = types.SimpleNamespace(SSHClient=_FakeClient, AutoAddPolicy=lambda: None)
os.environ["FISHBALL_TX_GATE"] = "python"
os.environ["BOARD"] = "203.0.113.9"
try:
    _FakeClient.answer = (3, b"", b"tx-guard: no affirmation on record for channel 1\n")
    try:
        tg.require_affirmation(1)
        check("python route: no affirmation is refused", False, "it returned")
    except tg.TxGateRefused as exc:
        check("python route: no affirmation is refused, with the python command to fix it",
              "python tools/tx_gate.py affirm 1" in str(exc), str(exc)[:120])
    check("python route: it pushes tx-guard.sh, then runs it with the arguments",
          _FakeClient.log[-2:] == ["cat > /tmp/tx-guard.sh", "sh /tmp/tx-guard.sh check 1"],
          repr(_FakeClient.log[-2:]))
    _FakeClient.answer = (0, b"tx-guard: ch0 attenuation verified at -40.00 dB\n", b"")
    got = tg.gated_set_atten(0, -40.0)
    check("python route: an affirmed write returns the read-back", got == -40.0, repr(got))
    _FakeClient.refuse_connect = True
    try:
        tg.gated_set_atten(0, -40.0)
        check("python route: an unreachable board is not permission", False, "it returned")
    except tg.TxGateRefused:
        check("python route: an unreachable board is not permission", False,
              "reported as a missing affirmation")
    except tg.TxGateError as exc:
        check("python route: an unreachable board is not permission", "exit 4" in str(exc),
              str(exc)[:120])
finally:
    for k in ("FISHBALL_TX_GATE", "BOARD"):
        os.environ.pop(k, None)
    sys.modules.pop("paramiko", None)


# --------------------------------------------------------------------------------
# 6. avg-level.py's published corrections, against a capture of KNOWN power.
#
# The ENBW direction was argued two different ways in review and neither matched. It
# is a measurement, so measure it.
# --------------------------------------------------------------------------------
try:
    import numpy as np

    fs, n, N = 4e6, int(4e6 * 2), 4096
    A, sigma = 0.15, 0.05
    rng = np.random.default_rng(7)
    t = np.arange(n)
    iq = A * np.exp(2j * np.pi * 1.0e6 * t / fs) \
        + rng.normal(0, sigma, n) + 1j * rng.normal(0, sigma, n)
    raw = np.empty(2 * n, dtype=np.int8)
    raw[0::2] = np.clip(np.round(iq.real * 127), -127, 127)
    raw[1::2] = np.clip(np.round(iq.imag * 127), -127, 127)
    with tempfile.NamedTemporaryFile(suffix=".cs8", delete=False) as f:
        raw.tofile(f.name)
        cap = f.name
    try:
        r = subprocess.run([sys.executable, str(CASES / "avg-level.py"), cap,
                            "4000000", "2399400000", "2400400000", "x:0:2"],
                           capture_output=True, text=True, timeout=120)
        cols = r.stdout.strip().splitlines()[-1].split()
        tgt, flr = float(cols[3]), float(cols[4])
        enbw = 1.5004 * fs / N
        tone_true = 10 * np.log10(A ** 2)
        noise_enbw = 10 * np.log10(2 * sigma ** 2) + 10 * np.log10(enbw / fs)
        check("avg-level: a tone reads 6.02 dB low (Hann coherent gain)",
              abs((tgt - tone_true) + 6.02) < 0.3, f"error {tgt - tone_true:+.2f} dB")
        check("avg-level: noise in one ENBW reads low by the SAME amount, so a "
              "tone-derived constant needs no correction",
              abs((flr - noise_enbw) - (tgt - tone_true)) < 0.3,
              f"tone {tgt - tone_true:+.2f} vs floor {flr - noise_enbw:+.2f} dB")
    finally:
        os.unlink(cap)
except ImportError:
    print("  SKIP  avg-level checks (numpy not installed)")


print(f"\n{CHECKS - len(FAILURES)}/{CHECKS} safety behaviours hold")
if FAILURES:
    print("\nFAILED:")
    for f in FAILURES:
        print(f"  - {f}")
sys.exit(1 if FAILURES else 0)
