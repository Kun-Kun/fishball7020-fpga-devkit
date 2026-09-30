#!/usr/bin/env python3
"""Read a BOOT.bin's partitions back out of it, and compare them.

    # run from: anywhere
    ./firmware/scripts/check_bootbin.py BOOT.bin
    ./firmware/scripts/check_bootbin.py BOOT.bin --xsa system_top.xsa
    ./firmware/scripts/check_bootbin.py BOOT.bin --ref other/BOOT.bin

Prints each partition with its offset, length and SHA-256, and fails unless the
image carries exactly the three this board boots from: fsbl.elf, system_top.bit,
u-boot.elf.

  --xsa FILE   the bitstream partition must be byte-identical to the XSA's own
               system_top.bit AFTER bootgen's conversion. bootgen stores a .bit as
               a raw .bin (header stripped), so hashing the .bit file directly never
               matches and proves nothing; this converts it the same way first.
  --ref FILE   compare every partition with the same-named one in another BOOT.bin,
               and say which are SAME. This is how "given the same XSA, the modern
               BOOT.bin is the factory one rebuilt" is checked rather than asserted:
               the FSBL and bitstream partitions should be the same; U-Boot carries
               a build timestamp, so it is reported, not required.
  --require-same NAME
               with --ref, make NAME's comparison the exit code: 0 same, 3 differs.
               Without it --ref only reports. A caller that must tell "different"
               from "could not compare" uses this rather than grepping the text.

WHY IT EXISTS. "BOOT.bin is several MB" was the only check the build had, and a
wrong bitstream, a missing U-Boot or the FSBL from another design are all several
MB too. The one question that matters for this board - is the FPGA image inside it
the one I meant - needs the partition out of the file and compared.

Exit 0 if every requested check holds; 1 if a check fails (wrong partitions, a
bitstream that does not match --xsa, a partition that runs past the end of the
file); 3 if a --require-same partition differs; 2 on a usage error; 4 if there
is no bootgen to read it with - "could not check", never "checked and bad".
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
WANT = ["fsbl.elf", "system_top.bit", "u-boot.elf"]


def find_bootgen(explicit):
    for c in (explicit,
              os.path.join(REPO, "firmware-modern", "boot", "bootgen", "bootgen"),
              os.path.join(REPO, "firmware", "src", "bootgen", "bootgen"),
              shutil.which("bootgen")):
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    print("ERROR: no bootgen found (pass --bootgen, or run ./devkit setup)", file=sys.stderr)
    sys.exit(4)


def partitions(bootgen, image):
    """[(name, offset_bytes, length_bytes)] as bootgen itself reads them.

    Offsets and lengths in the partition header table are in 32-bit WORDS."""
    out = subprocess.run([bootgen, "-arch", "zynq", "-read", image],
                         capture_output=True, text=True).stdout
    parts = []
    for block in re.split(r"PARTITION HEADER TABLE \(", out)[1:]:
        name = block.split(")", 1)[0].rsplit(".", 1)[0]
        tl = re.search(r"total_length \(0x08\) : (0x[0-9a-fA-F]+)", block)
        po = re.search(r"partition_offset \(0x14\) : (0x[0-9a-fA-F]+)", block)
        if tl and po:
            parts.append((name, int(po.group(1), 16) * 4, int(tl.group(1), 16) * 4))
    return parts


def payload(image, off, length):
    """The partition's bytes, or None if it runs past the end of the file.

    A truncated BOOT.bin used to PASS: its header still lists three partitions, and
    reading past the end quietly returns fewer bytes. Refuse instead."""
    with open(image, "rb") as f:
        f.seek(off)
        b = f.read(length)
    return b if len(b) == length else None


def converted_bitstream(bootgen, xsa):
    """The XSA's bitstream, converted the way bootgen stores it in a BOOT.bin."""
    with tempfile.TemporaryDirectory() as d:
        with zipfile.ZipFile(xsa) as z:
            with open(os.path.join(d, "system_top.bit"), "wb") as f:
                f.write(z.read("system_top.bit"))
        with open(os.path.join(d, "b.bif"), "w") as f:
            f.write("img:{system_top.bit}\n")
        subprocess.run([bootgen, "-arch", "zynq", "-process_bitstream", "bin",
                        "-image", "b.bif", "-w"], cwd=d, capture_output=True)
        p = os.path.join(d, "system_top.bit.bin")
        if not os.path.isfile(p):
            sys.exit("ERROR: bootgen did not convert the XSA's bitstream")
        with open(p, "rb") as f:
            return f.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("image")
    ap.add_argument("--xsa")
    ap.add_argument("--ref")
    ap.add_argument("--bootgen")
    ap.add_argument("--require-same")
    a = ap.parse_args()
    if not os.path.isfile(a.image):
        print(f"ERROR: no such file: {a.image}", file=sys.stderr)
        return 2
    bg = find_bootgen(a.bootgen)
    ok = True

    parts = partitions(bg, a.image)
    names = [p[0] for p in parts]
    print(f"  {os.path.basename(a.image)}: {os.path.getsize(a.image)} bytes, "
          f"{len(parts)} partitions")
    for name, off, ln in parts:
        b = payload(a.image, off, ln)
        if b is None:
            print(f"    {name:<16} offset {off:>9}  length {ln:>9}  RUNS PAST THE END OF THE FILE")
            ok = False
            continue
        print(f"    {name:<16} offset {off:>9}  length {ln:>9}  sha256 {hashlib.sha256(b).hexdigest()[:16]}")
    if not ok:
        print(f"  FAIL  the image is truncated: a partition ends beyond "
              f"{os.path.getsize(a.image)} bytes")
    if names != WANT:
        print(f"  FAIL  expected exactly {WANT}, found {names}")
        ok = False
    else:
        print(f"  PASS  exactly the three partitions this board boots from")

    if a.xsa:
        bit = next((p for p in parts if p[0] == "system_top.bit"), None)
        want = converted_bitstream(bg, a.xsa)
        got = payload(a.image, bit[1], bit[2]) if bit else None
        if got is not None and got == want:
            print(f"  PASS  bitstream partition is byte-identical to the XSA's "
                  f"({len(want)} bytes, sha256 {hashlib.sha256(want).hexdigest()[:16]})")
        else:
            print(f"  FAIL  bitstream partition does NOT match {a.xsa}")
            ok = False

    required = None
    if a.ref:
        ref = {n: (o, l) for n, o, l in partitions(bg, a.ref)}
        for name, off, ln in parts:
            if name not in ref:
                print(f"  --    {name}: not in {a.ref}")
                continue
            mine, theirs = payload(a.image, off, ln), payload(a.ref, *ref[name])
            same = mine is not None and mine == theirs
            print(f"  {'SAME ' if same else 'DIFF '} {name} vs {os.path.basename(a.ref)}")
            if name == a.require_same:
                required = same
        if a.require_same and required is None:
            print(f"  FAIL  --require-same {a.require_same}: not a partition of both images")
            ok = False
    if not ok:
        return 1
    if required is False:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
