#!/usr/bin/env python3
"""Audit a built device tree against what this board actually needs.

    # run from: the repo root
    python3 firmware-modern/verify_dtb.py firmware-modern/src/linux/arch/arm/boot/dts/xilinx/zynq-pluto-sdr-fishball.dtb

Checks the COMPILED tree, not the source, because the source is an overlay: most
of what ends up in the .dtb comes from ADI's zynq-pluto-sdr.dtsi, and the two
bugs this found during bring-up were both invisible in the .dts.

  * a memory@0 node became a SIBLING of the dtsi's memory rather than an
    override, so the tree carried both 512 MB and 1 GB. dtc said only
    "duplicate unit-address" against an unrelated node.
  * ADI's dtsi has &sdhci0 { status = "disabled" } - a Pluto boots from QSPI.
    That cost a card-reader trip, because tools/flash.sh works by mounting
    /dev/mmcblk0p1 on the running board.

Both would have booted. So every check here is a thing that boots wrong rather
than a thing that fails to build, which is why it is worth having at all.

The node-status reference is the FACTORY tree, recovered from
firmware/patches/0002 - a 986-line flat DTS decompiled from the factory .dtb.
That is the only authority for what this board's hardware is, so an enabled node
missing here is a capability the board has and this firmware does not.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FACTORY_PATCH = f"{REPO}/firmware/patches/0002-add-fishball-devicetree.patch"

# The AD9361 delta from a stock Pluto: nine properties, established by parsing
# both trees rather than by eye. Values matter for two of them and the rest are
# flags, so a present/absent test is the right shape.
AD9361_VALUES = {
    # 89750 mdB. ADI ships 10000 - 10 dB - applied to BOTH channels inside
    # ad9361_setup(), before any userspace runs and again on every debugfs
    # "initialize". On a board with a power amplifier that is roughly +9 dBm out
    # of an SMA nobody has necessarily terminated. main needs patch 0011 for
    # this; here it is the value in the tree, which is strictly better because a
    # patch can be forgotten. THE SINGLE MOST SAFETY-CRITICAL LINE IN THE TREE.
    "adi,tx-attenuation-mdB": 89750,
    "adi,rx-data-delay": 4,
    "adi,tx-fb-clock-delay": 7,
    "adi,lvds-bias-mV": 150,
}
AD9361_FLAGS = [
    "adi,2rx-2tx-mode-enable",          # the board is 2R2T; a Pluto is 1R1T
    "adi,lvds-mode-enable",
    "adi,lvds-rx-onchip-termination-enable",
]

# Nodes this board has that a Pluto does not, so ADI's dtsi leaves them off.
# Keyed by NODE NAME, not by path: the factory tree calls the bus /amba and
# ADI's dtsi calls it /axi, so comparing full paths finds nothing in common and
# reports a clean bill of health for two trees that share almost every node.
# Unit addresses make these names unique anyway.
MUST_BE_OKAY = {
    "ethernet@e000b000": "Ethernet (RTL8211F). Without it there is no network.",
    "mmc@e0100000": "the SD card. Without it tools/flash.sh cannot work at "
                    "all - it mounts /dev/mmcblk0p1 on the running board.",
}


def dts_of(path: str) -> str:
    """Decompile a .dtb, or read a .dts as-is."""
    if path.endswith(".dts"):
        return open(path).read()
    for dtc in (f"{REPO}/firmware-modern/src/linux/scripts/dtc/dtc", "dtc"):
        try:
            return subprocess.run([dtc, "-I", "dtb", "-O", "dts", path],
                                  capture_output=True, text=True,
                                  check=True).stdout
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
    sys.exit("no dtc available - build one with 'make scripts_dtc' in the kernel tree")


def factory_dts() -> str:
    """The factory tree, out of the patch that creates it."""
    body = open(FACTORY_PATCH).read()
    body = body[body.index("@@ -0,0"):]
    return "\n".join(l[1:] for l in body.splitlines()[1:] if l.startswith("+"))


def walk(dts: str) -> dict[str, dict[str, str]]:
    """{node path: {property: value}}. Brace depth is enough for real trees."""
    out, stack = {}, []
    for raw in dts.splitlines():
        line = raw.split("//")[0].strip()
        if not line or line.startswith(("/dts-v1/", "#", "/*", "*")):
            continue
        # The root is "/ {" and every other node is "[label:] name {". Push a
        # placeholder for the root so a path is just "/" + the rest joined:
        # forgetting that silently shifts every path up one level, and then
        # every lookup misses while the tree looks fine.
        if re.match(r"^/\s*\{", line):
            stack.append("")
            out.setdefault("/", {})
            continue
        m = re.match(r"^(?:([\w,.+-]+)\s*:\s*)?([\w,.@+-]+)\s*\{", line)
        if m:
            stack.append(m.group(2))
            out.setdefault("/" + "/".join(stack[1:]), {})
            continue
        if line.startswith("}"):
            if stack:
                stack.pop()
            continue
        m = re.match(r"^([\w,.+#-]+)\s*(?:=\s*(.*?))?\s*;$", line)
        if m and stack:
            out.setdefault("/" + "/".join(stack[1:]), {})[m.group(1)] = \
                (m.group(2) or "").strip()
    return out


def strings(value: str) -> list[str]:
    """A string-list property, from either form it can arrive in.

    Source .dts gives '"a", "b"'. A DECOMPILED .dtb gives cells, because a .dtb
    records no types - so gpio-line-names comes back as <0x00 0x00 ... 0x73616d70
    ...>, which is 72 NUL-terminated empty strings followed by four names. Both
    are the same property; only one of them is readable. Checking the source form
    alone means the check passes on the .dts and silently never fires on the .dtb,
    which is the file that gets flashed.
    """
    if '"' in value:
        return re.findall(r'"([^"]*)"', value)
    raw = b"".join(c.to_bytes(4, "big") for c in ints(value))
    return raw.split(b"\0")[:-1] and [s.decode("utf-8", "replace")
                                      for s in raw.split(b"\0")[:-1]]


def ints(value: str) -> list[int]:
    """Cell values out of <...>, hex or decimal, /bits/ 64 tolerated."""
    return [int(t, 16) if t.lower().startswith("0x") else int(t)
            for t in re.findall(r"0x[0-9a-fA-F]+|\b\d+\b",
                                " ".join(re.findall(r"<([^>]*)>", value)))]


def main(argv) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    built = walk(dts_of(argv[1]))
    factory = walk(factory_dts())
    by_name = {p.rsplit("/", 1)[-1]: v for p, v in built.items()}
    fails, notes = [], []

    def check(ok: bool, msg: str, why: str = ""):
        (notes if ok else fails).append((msg, why))

    # ---- memory: exactly one node, and 1 GB of it ------------------------
    mems = [p for p in built if re.fullmatch(r"/memory(@.*)?", p)]
    check(len(mems) == 1,
          f"exactly one memory node ({', '.join(mems) or 'none'})",
          "two memory nodes means the kernel picks one and you get 512 MB on a "
          "1 GB board, or worse. An override must match the dtsi's node NAME "
          "exactly - 'memory', not 'memory@0'.")
    if mems:
        cells = ints(built[mems[0]].get("reg", ""))
        size = cells[-1] if cells else 0
        check(size == 0x40000000, f"memory is {size / 2**20:.0f} MiB",
              "this board has 1 GB; ADI's dtsi declares 512 MB for a Pluto.")

    # ---- nodes the board has and a Pluto does not ------------------------
    for name, why in MUST_BE_OKAY.items():
        st = by_name.get(name, {}).get("status", '"okay"')
        check(name in by_name and st == '"okay"',
              f"{name} is {st if name in by_name else 'MISSING'}", why)

    # ---- nothing the factory enables may be off here ---------------------
    lost = []
    for path, props in factory.items():
        if props.get("status") != '"okay"':
            continue
        name = path.rsplit("/", 1)[-1]
        if name not in by_name:
            lost.append(f"{name} (absent)")
        elif by_name[name].get("status", '"okay"') != '"okay"':
            lost.append(f"{name} ({by_name[name]['status']})")
    check(not lost, f"every node the factory tree enables is enabled here"
                    + (f" - LOST: {', '.join(lost)}" if lost else ""),
          "an enabled node missing here is a piece of hardware this firmware "
          "cannot reach. This check is what found mmc@e0100000.")

    # ---- the AD9361 -----------------------------------------------------
    phy = next((p for p, v in built.items()
                if v.get("compatible", "").strip('"') == "adi,ad9361"), None)
    check(phy is not None, f"the AD9361 node is {phy}",
          "nothing below can be checked without it.")
    if phy:
        for prop, want in AD9361_VALUES.items():
            got = ints(built[phy].get(prop, ""))
            check(got[:1] == [want],
                  f"{prop} = {got[0] if got else 'ABSENT'} (want {want})",
                  "THE TRANSMITTERS COME UP AT THIS ATTENUATION, before any "
                  "userspace runs. 10 dB here is roughly +9 dBm out of an SMA."
                  if prop == "adi,tx-attenuation-mdB" else
                  "a measured interface setting for this board's LVDS timing.")
        for flag in AD9361_FLAGS:
            check(flag in built[phy], f"{flag} present",
                  "without 2rx-2tx the second chain does not exist."
                  if "2rx-2tx" in flag else "part of the LVDS interface setup.")

    # ---- the DMA descriptors older DMAC cores need -----------------------
    found = [p for p in built if "adi,channels/dma-channel" in p]
    check(len(found) == 2,
          f"{len(found)} adi,channels/dma-channel descriptors (want 2)",
          "dma-axi-dmac.c configures itself from hardware only for cores "
          ">= 4.3.a. This board's bitstream is ADI's 2018-era HDL, so the "
          "older path runs axi_dmac_parse_dt(), which returns -ENODEV without "
          "these. A failed DMA probe means nothing streams at all.")

    # ---- the sample-locked GPIO lines (main's patch 0008) ----------------
    named = [p for p, v in built.items() if "gpio-line-names" in v]
    lines = [n for p in named for n in strings(built[p]["gpio-line-names"])]
    check(all(f"sample_gpio{i}" in lines for i in range(4)),
          f"the four sample_gpio lines are named"
          + ("" if named else " - gpio-line-names is ABSENT"),
          "docs and the agent skill both say to resolve these with "
          "'gpiofind sample_gpio0'. Without the names that returns nothing and "
          "the only route left is a hard-coded line number, which moves.")

    # ---- and the tree must NOT ask for the tx-active LED trigger ---------
    check(not any("tx-active" in v.get("linux,default-trigger", "")
                  for v in built.values()),
          "the user LED still asks for heartbeat, not tx-active",
          "patch 0012's rootfs half selects the trigger at boot. Putting it in "
          "the tree instead means a board with no transmitter activity looks "
          "dead rather than idle.")

    width = max(len(m) for m, _ in fails + notes)
    for msg, _ in notes:
        print(f"  ok    {msg}")
    for msg, why in fails:
        print(f"  FAIL  {msg}")
        for line in re.findall(r".{1,72}(?:\s|$)", why):
            print(f"        {line.strip()}")
    print(f"\n{len(notes)} passed, {len(fails)} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
