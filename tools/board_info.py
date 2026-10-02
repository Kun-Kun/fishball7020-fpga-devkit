#!/usr/bin/env python3
"""What is the board running? Read over IIOD, so no password and no ssh.

    # run from: the repo root
    python3 tools/board_info.py            # the board found by board_addr.py
    python3 tools/board_info.py HOST

Prints one "key: value" line each for where the board is, its model, the
firmware it runs (factory or modern, and the version) and its kernel. Exit 0
if the board answered, 3 if only its ssh did (iiod is down), 1 if nothing did.
`./devkit status` uses it.

The firmware is told apart by what the board publishes: the modern (Debian)
firmware's fishball-identity service adds `fw_build`, the full `git describe`
of the build; the factory (Buildroot) firmware does not.
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.join(HERE, "selftest")]
from board_addr import check                                     # noqa: E402
from iiod_min import Iiod                                        # noqa: E402


def describe(attrs: dict[str, str]) -> list[tuple[str, str]]:
    kernel = attrs.get("local,kernel", "?")
    if "fw_build" in attrs:
        fw = f"modern (Debian), {attrs['fw_build']}"
    else:
        fw = f"factory (Buildroot), {attrs.get('fw_version', '?')}"
    return [("model", attrs.get("hw_model", "?")),
            ("firmware", fw),
            ("kernel", kernel)]


def main(argv: list[str]) -> int:
    code, host = check(argv[0] if argv else None)
    if code == 3:
        print(f"address: {host}")
        print("iiod: not answering - only ssh does")
    if code != 0:
        return code
    try:
        with Iiod(host, timeout=5.0) as io:
            attrs = io.context_attrs()
    except OSError:
        return 1
    print(f"address: {host}")
    for k, v in describe(attrs):
        print(f"{k}: {v}")
    return 0


if __name__ == "__main__":
    if any(a in ("-h", "--help") for a in sys.argv[1:]):
        print(__doc__.strip())
        raise SystemExit(0)
    rc = main(sys.argv[1:])
    sys.stdout.flush()
    os._exit(rc)        # do not wait on a name lookup still running in a thread
