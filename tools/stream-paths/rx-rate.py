#!/usr/bin/env python3
"""How fast can the board stream RX2 to this PC, and what does it cost the board?

    # run from: the repo root, on your PC
    tools/stream-paths/rx-rate.py                         # sweep 5 .. 30.72 MS/s, 12 s each
    tools/stream-paths/rx-rate.py 10 11 12                # chosen rates, in MS/s
    tools/stream-paths/rx-rate.py --confirm 11            # one 60 s run at 11 MS/s
    tools/stream-paths/rx-rate.py --reader "nc HOST 5555" 20   # any other reader on stdout
    tools/stream-paths/rx-rate.py --reader "nc HOST 5556" --bps 2 --proc zc-stream 20
                                                          # zc-stream -D -8: RX2, int8

For each rate it sets the AD9361's sample rate (read back: some rates round by
1 Hz) with the FPGA filter bypassed, streams RX2 only (voltage2 + voltage3,
4 bytes per sample) for 12 s, and times the bytes that arrive over seconds 3-12,
so the stream's start-up does not count. "% of samples" is what arrived over
what the rate produces; 99.5% or more over 60 s is a sustained rate.

It also samples the board's CPU while streaming (top, over ssh), refuses to run
while SDR++ is open or a Hardware CI run holds the board, checks both
transmitters read -89.75 dB before and after (it never transmits), and leaves
the board at rest: 3 MS/s, FPGA filter bypassed, slow_attack on both receivers.
"""
import argparse
import os
import re
import shlex
import subprocess
import sys
import threading
import time

MUTED = -89.75


def sh(*cmd, check=True):
    return subprocess.run(cmd, capture_output=True, text=True, check=check).stdout.strip()


class Board:
    def __init__(self, host, ssh_target):
        self.uri = f"ip:{host}"
        self.ssh_target = ssh_target

    def attr(self, *a):
        return sh("iio_attr", "-u", self.uri, *a)

    def ssh(self, cmd):
        return sh("ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", self.ssh_target, cmd, check=False)

    def tx_atten(self):
        return [float(self.attr("-o", "-c", "ad9361-phy", f"voltage{c}", "hardwaregain").split()[0]) for c in (0, 1)]

    def set_rate(self, rate):
        self.attr("-i", "-c", "ad9361-phy", "voltage0", "sampling_frequency", str(rate))
        phy = int(self.attr("-i", "-c", "ad9361-phy", "voltage0", "sampling_frequency"))
        try:
            self.attr("-c", "cf-ad9361-lpc", "voltage0", "sampling_frequency", str(phy))
        except subprocess.CalledProcessError:
            pass                        # rates the FPGA filter does not list: it is bypassed anyway
        return phy

    def rest(self):
        self.set_rate(3_000_000)
        self.attr("-i", "-c", "ad9361-phy", "voltage0", "rf_bandwidth", "3000000")
        for c in (0, 1):
            self.attr("-i", "-c", "ad9361-phy", f"voltage{c}", "gain_control_mode", "slow_attack")


def preflight(board, ignore_ci):
    if subprocess.run(["pgrep", "-x", "sdrpp"], capture_output=True).returncode == 0:
        sys.exit("SDR++ is running: close it first, or both streams share the board and both numbers are wrong.")
    if not ignore_ci:
        r = subprocess.run(["gh", "run", "list", "-w", "Hardware", "-L", "3", "--json", "status", "-q",
                            '.[].status'], capture_output=True, text=True)
        if r.returncode == 0 and re.search(r"in_progress|queued|waiting", r.stdout):
            sys.exit("A Hardware CI run is using the board: wait for it (gh run list).")
    att = board.tx_atten()
    if any(a > MUTED + 0.26 for a in att):
        sys.exit(f"A transmitter is not muted ({att} dB): refusing to run.")


def cpu_sampler(board, proc_name, out, stop):
    """Board-wide CPU busy % and the named process's %, from top, every ~3 s."""
    while not stop.is_set():
        awk = "awk '/^%Cpu/{c=$0} $NF==\"NAME\"{p=$9} END{print c\"|\"p}'".replace("NAME", proc_name)
        txt = board.ssh("top -b -n 2 -d 2 | " + awk)
        m = re.search(r"([\d.]+)\s*id", txt)
        if m:
            p = txt.split("|")[-1].strip()
            out.append((100 - float(m.group(1)), float(p) if p else None))
        stop.wait(1)


def run(board, rate, secs, reader, proc_name, bps):
    phy = board.set_rate(rate)
    cmd = shlex.split(reader.format(uri=board.uri, buf=1 << 20))
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    cpu, stop = [], threading.Event()
    th = threading.Thread(target=cpu_sampler, args=(board, proc_name, cpu, stop), daemon=True)
    t0 = time.time()
    n, marks, started = 0, [], False
    while time.time() - t0 < secs:
        d = p.stdout.read1(1 << 20)
        if not d:
            break
        n += len(d)
        marks.append((time.time() - t0, n))
        if not started and time.time() - t0 > 3:
            th.start(); started = True
    stop.set()
    p.kill(); p.wait()
    a = next(((t, b) for t, b in marks if t >= 3), None)
    if not a or marks[-1][0] - a[0] < 4:
        return phy, 0.0, 0.0, cpu
    mbps = (marks[-1][1] - a[1]) / (marks[-1][0] - a[0]) / 1e6
    return phy, mbps, mbps / (phy * bps / 1e6) * 100, cpu


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rates", nargs="*", type=float, help="MS/s (default 5 10 15 20 25 30.72)")
    ap.add_argument("--host", default=os.environ.get("BOARD", "192.168.129.165"))
    ap.add_argument("--ssh", default="fishball", help="ssh target for the CPU sampler (default: the ssh-key alias)")
    ap.add_argument("--secs", type=float, default=12)
    ap.add_argument("--confirm", type=float, metavar="MSPS", help="one 60 s run at this rate")
    ap.add_argument("--reader", default="iio_readdev -u {uri} -b {buf} cf-ad9361-lpc voltage2 voltage3",
                    help="command that writes the RX2 stream to stdout ({uri}, {buf} are filled in)")
    ap.add_argument("--proc", default="iiod", help="board process whose CPU %% to report")
    ap.add_argument("--bps", type=int, default=4, help="bytes per sample on the wire: 4 for int16, 2 for int8")
    ap.add_argument("--ignore-ci", action="store_true")
    a = ap.parse_args()

    board = Board(a.host, a.ssh)
    preflight(board, a.ignore_ci)
    rates, secs = ([a.confirm], 63) if a.confirm else (a.rates or [5, 10, 15, 20, 25, 30.72], a.secs)
    print(f"board {board.uri}, reader: {a.reader.split()[0]}, {secs:.0f} s per rate, timed over seconds 3-{secs:.0f}")
    print(f"{'rate':>9} {'needs':>11} {'got':>11} {'samples':>8} {'board CPU':>10} {a.proc + ' CPU':>10}")
    try:
        for r in rates:
            phy, mbps, pct, cpu = run(board, int(r * 1e6), secs, a.reader, a.proc, a.bps)
            tot = max((c[0] for c in cpu), default=float("nan"))
            prc = max((c[1] for c in cpu if c[1] is not None), default=float("nan"))
            print(f"{phy/1e6:6.2f} MS/s {phy*a.bps/1e6:7.1f} MB/s {mbps:7.1f} MB/s {pct:7.1f}% {tot:9.0f}% {prc:9.0f}%",
                  flush=True)
    finally:
        board.rest()
        att = board.tx_atten()
        print(f"board at rest: 3 MS/s, slow_attack; transmitters {att[0]} / {att[1]} dB")
        if any(x > MUTED + 0.26 for x in att):
            sys.exit("*** a transmitter is NOT muted ***")


if __name__ == "__main__":
    main()
