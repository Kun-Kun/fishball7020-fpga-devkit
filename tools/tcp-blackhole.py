#!/usr/bin/env python3
"""A TCP relay that can black-hole a connection without closing it.

    # run from: the repo root, on your HOST
    ./tools/tcp-blackhole.py --to fishball.local:30431 --listen 127.0.0.1:34310 \
        --drop-when /tmp/drop --exit-when /tmp/done      # --chunk defaults to 1 MB
    iio_writedev -u ip:127.0.0.1:34310 ...      # point the client at the relay
    touch /tmp/drop                             # the network "goes away"

WHY THIS EXISTS. Testing what the transmitter does when a streaming client's
NETWORK drops is not the same test as killing the client. Killing it closes its
socket: the host's kernel sends a FIN, iiod sees the disconnect and tidies up
after it - which is why IDLE-CASES.md's first attempt at a "network drop" case
was really the process-kill case with an extra signal in front of it. A genuine
drop delivers no FIN and no RST. The peer simply stops hearing anything, and its
socket stays ESTABLISHED until a TCP timeout it may never reach.

You can produce that with a firewall rule, which needs root and reaches every
flow on the box. This does it in userspace for one client: on the sentinel it
stops copying bytes in both directions and then holds every socket open, never
closing them. From the board's side the client has vanished mid-stream with the
connection still up, which is exactly the condition under test.

    the relay is holding the board-side sockets open, so DO NOT KILL IT while
    measuring - process exit closes them and the OS sends the FIN you were
    trying not to send. It exits on --exit-when, or on SIGINT when you have
    finished.

IT MUST RELAY MORE THAN ONE CONNECTION. libiio's network backend opens a second
socket for each buffer, so a one-connection relay passes iio_info and fails
every stream, as an unexplained client-side "Open unlocked: -32". All flows are
dropped together, which is also what losing a network does.

It is a test instrument, not a proxy to leave running: no TLS, no reconnect, and
it stops accepting once dropped.
"""
from __future__ import annotations

import argparse
import os
import select
import socket
import sys
import threading
import time

_TALLY_LOCK = threading.Lock()



def hostport(s: str, what: str) -> tuple[str, int]:
    if ":" not in s:
        sys.exit(f"--{what} needs HOST:PORT, got {s!r}")
    h, _, p = s.rpartition(":")
    return h, int(p)


def stamp() -> str:
    return f"{time.time():.3f}"


def pump(src: socket.socket, dst: socket.socket, dropped: threading.Event,
         label: str, quiet: bool, tally: dict, chunk: int = 65536) -> None:
    """Copy until the drop, then stop - WITHOUT closing either socket.

    `tally[label]` accumulates bytes forwarded, so the caller can show the
    connection was actually carrying the stream at the moment it was dropped. A
    drop on a connection that had already failed measures nothing.

    select() decides when to read, NOT socket.settimeout(). A timeout set for
    this thread's recv applies to the whole socket, including the sendall the
    OTHER thread does on it, so a send that blocked for 50 ms on a full send
    buffer raised socket.timeout - an OSError - and tore the relay down
    mid-stream. That is not hypothetical: it is how the first attempt at this
    failed, and it failed silently, as a client-side "Open unlocked: -32".
    """
    try:
        while not dropped.is_set():
            r, _, _ = select.select([src], [], [], 0.05)
            if not r:
                continue
            try:
                data = src.recv(chunk)
            except OSError:
                break
            if not data:
                break                      # a real close from this side
            if dropped.is_set():
                break                      # do not deliver what arrived late
            try:
                dst.sendall(data)          # blocking: flow control, not a timeout
                # Locked: two threads share this dict, and the byte count is
                # quoted as evidence that the connection was carrying the stream
                # when it was dropped. A lost update understates that evidence.
                with _TALLY_LOCK:
                    tally[label] = tally.get(label, 0) + len(data)
            except OSError:
                break
    finally:
        if not quiet:
            print(f"[{stamp()}] {label}: stopped copying "
                  f"({'blackholed' if dropped.is_set() else 'peer closed'})", flush=True)


def accept_loop(srv: socket.socket, target: tuple[str, int], dropped: threading.Event,
                held: list, tally: dict, quiet: bool, sndbuf: int,
                chunk: int = 65536) -> None:
    n = 0
    while not dropped.is_set():
        r, _, _ = select.select([srv], [], [], 0.05)
        if not r:
            continue
        client, caddr = srv.accept()
        n += 1
        try:
            upstream = socket.create_connection(target, timeout=10)
        except OSError as exc:
            print(f"[{stamp()}] flow {n}: upstream {target} refused: {exc}", flush=True)
            client.close()
            continue
        client.settimeout(None)
        upstream.settimeout(None)           # blocking; see pump()
        # Bound how much is IN FLIGHT when the drop happens. Whatever is already
        # in the kernel's send buffer is delivered by the kernel whether this
        # process cooperates or not, and at a DMA stream's data rate an
        # auto-tuned megabyte of it is a few hundred milliseconds of samples -
        # the same order as the watchdog being measured. A small send buffer
        # keeps that tail short, and the 128 KB default is still well above a
        # LAN's bandwidth-delay product, so throughput is unaffected. Some
        # queueing is
        # inherent: a real network drop also leaves the peer holding whatever
        # had already arrived.
        if sndbuf:
            upstream.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, sndbuf)
        held.append((client, upstream))
        print(f"[{stamp()}] flow {n}: client {caddr} <-> upstream "
              f"{upstream.getsockname()[:2]} -> {upstream.getpeername()[:2]}, "
              f"SO_SNDBUF={upstream.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)}",
              flush=True)
        for s, d, lab in ((client, upstream, f"flow{n} client->board"),
                          (upstream, client, f"flow{n} board->client")):
            threading.Thread(target=pump, args=(s, d, dropped, lab, quiet, tally, chunk),
                             daemon=True).start()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--to", required=True, help="where the real service is, HOST:PORT")
    ap.add_argument("--listen", default="127.0.0.1:34310", help="HOST:PORT to accept on")
    ap.add_argument("--drop-when", required=True,
                    help="path that, once it exists, black-holes every flow")
    ap.add_argument("--exit-when",
                    help="path that, once it exists, CLOSES the sockets and exits. "
                         "Closing sends the FIN the drop was avoiding, so only "
                         "create this after you have finished measuring.")
    ap.add_argument("--sndbuf", type=int, default=131072,
                    help="SO_SNDBUF on the board-side socket, bytes (default 131072). "
                         "It bounds the tail the kernel delivers AFTER the drop - at a "
                         "12 MB/s stream, 128 KB is about 10 ms of samples - but too "
                         "small a value throttles the stream and starves the DAC before "
                         "you get to drop anything. 0 leaves the kernel's auto-tuning "
                         "alone, and the tail then runs to hundreds of milliseconds.")
    ap.add_argument("--chunk", type=int, default=1048576,
                    help="bytes per recv/send (default 1048576). 64 KB was the old "
                         "default and it is the reason a committed measurement in "
                         "IDLE-CASES.md was wrong: on a slow CPU the per-syscall "
                         "overhead at 64 KB starves a DAC being fed through the relay, "
                         "which looks exactly like the board being unable to keep up. "
                         "Lower it only if you want to reproduce that.")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    lh, lp = hostport(a.listen, "listen")
    th, tp = hostport(a.to, "to")
    if os.path.exists(a.drop_when):
        sys.exit(f"--drop-when {a.drop_when} already exists; remove it first, or every "
                 f"flow is black-holed before it carries anything")

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((lh, lp))
    srv.listen(8)
    print(f"[{stamp()}] relay {lh}:{srv.getsockname()[1]} -> {th}:{tp}; "
          f"drop on {a.drop_when}", flush=True)

    dropped = threading.Event()
    held: list = []                     # references, so nothing is ever closed early
    tally: dict[str, int] = {}
    threading.Thread(target=accept_loop,
                     args=(srv, (th, tp), dropped, held, tally, a.quiet, a.sndbuf,
                           a.chunk),
                     daemon=True).start()

    while not os.path.exists(a.drop_when):
        time.sleep(0.02)
    dropped.set()
    # Stop listening as soon as the drop lands: a connection accepted after it
    # would be neither relayed nor dropped, just silently stuck.
    try:
        srv.close()
    except OSError:
        pass
    with _TALLY_LOCK:
        snapshot = dict(tally)
    fwd = ", ".join(f"{k} {v / 1e6:.2f} MB" for k, v in sorted(snapshot.items())) or "nothing"
    print(f"[{stamp()}] BLACKHOLED {len(held)} flow(s) - no FIN, no RST; "
          f"sockets held open; forwarded {fwd}", flush=True)

    # Hold the sockets. `held` keeping them referenced and unclosed is the whole
    # mechanism: while this process lives, the board's connections stay
    # ESTABLISHED with a client that will never speak again.
    try:
        while not (a.exit_when and os.path.exists(a.exit_when)):
            time.sleep(0.05)
    except KeyboardInterrupt:
        print(f"[{stamp()}] interrupted", flush=True)
    for c, u in held:
        c.close()
        u.close()
    print(f"[{stamp()}] {len(held)} flow(s) closed (the board now sees the FIN)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
