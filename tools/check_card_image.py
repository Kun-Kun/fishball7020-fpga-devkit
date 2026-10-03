#!/usr/bin/env python3
"""Check an SD card image against the release files it was written from.

    # run from: the repo root, on Linux, as root (it loop-mounts the image)
    sudo python3 tools/check_card_image.py card.img RELEASE_DIR

Checks the partition table (128 MB FAT32 at sector 2048, Linux after it), runs
fsck.vfat and e2fsck on both partitions, then mounts them read-only and
compares every boot file and every entry of debian-rootfs.tar.gz - type,
permissions, owner, timestamp, symlink target, hardlink and contents. Works on
a raw image and on a fixed VHD (a raw image with a 512-byte footer). Exit 0
only if everything matches.

Written for tools/write-card.cmd, whose CI job writes a virtual disk on Windows
and hands it here, but it checks a card made any other way just as well.
"""
import hashlib
import os
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile

BOOT_FILES = ["BOOT.bin", "uImage", "devicetree.dtb", "uEnv.txt"]


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    image, rel = sys.argv[1], sys.argv[2]

    with open(image, "rb") as f:
        mbr = f.read(512)
    if mbr[510:512] != b"\x55\xaa":
        fail("no partition table")
    parts = []
    for i in range(4):
        e = mbr[446 + 16 * i: 462 + 16 * i]
        ptype = e[4]
        lba, count = struct.unpack_from("<II", e, 8)
        if ptype:
            parts.append((e[0], ptype, lba, count))
    print("partitions:", [(hex(t), lba, count) for _, t, lba, count in parts])
    if len(parts) != 2 or parts[0][1:4] != (0x0C, 2048, 262144) or parts[0][0] != 0x80:
        fail("p1 is not a bootable 128 MB FAT32 (0x0C) partition at sector 2048")
    if parts[1][1] != 0x83 or parts[1][2] != 2048 + 262144:
        fail("p2 is not a Linux (0x83) partition right after p1")

    sums = {}
    for line in open(os.path.join(rel, "SHA256SUMS")):
        h, name = line.split()
        sums[name.lstrip("*")] = h

    with tempfile.TemporaryDirectory() as tmp:
        p1, p2 = os.path.join(tmp, "p1.img"), os.path.join(tmp, "p2.img")
        for path, (_, _, lba, count) in ((p1, parts[0]), (p2, parts[1])):
            subprocess.run(["dd", "if=" + image, "of=" + path, "bs=512", "skip=%d" % lba,
                            "count=%d" % count, "status=none", "conv=sparse"], check=True)
        for cmd in (["fsck.vfat", "-n", p1], ["e2fsck", "-fn", p2]):
            r = subprocess.run(cmd, capture_output=True, text=True)
            print("$ " + " ".join(cmd[:2]) + "\n" + r.stdout.strip().splitlines()[-1])
            if r.returncode != 0:
                print(r.stdout + r.stderr)
                fail(cmd[0] + " found problems")
        label = subprocess.run(["e2label", p2], capture_output=True, text=True).stdout.strip()
        if label != "fishroot":
            fail("root label is %r, not 'fishroot' (fstab mounts it by label)" % label)

        m1, m2 = os.path.join(tmp, "m1"), os.path.join(tmp, "m2")
        os.mkdir(m1)
        os.mkdir(m2)
        subprocess.run(["mount", "-o", "ro,loop", p1, m1], check=True)
        subprocess.run(["mount", "-o", "ro,loop,noload", p2, m2], check=True)
        try:
            for name in BOOT_FILES:
                if sha(open(os.path.join(m1, name), "rb").read()) != sums[name]:
                    fail("boot partition: %s differs from SHA256SUMS" % name)
            print("boot partition: %s match SHA256SUMS" % ", ".join(BOOT_FILES))
            check_root(m2, os.path.join(rel, "debian-rootfs.tar.gz"))
        finally:
            subprocess.run(["umount", m1, m2])
    print("PASS")


def check_root(root, tgz):
    t = tarfile.open(tgz)
    bad, n, seen = [], 0, {""}
    for m in t:
        p = m.name
        while p.startswith("./"):
            p = p[2:]
        p = p.strip("/")
        fp = os.path.join(root, p)
        n += 1
        seen.add(p)
        try:
            st = os.lstat(fp)
        except FileNotFoundError:
            bad.append("missing " + p)
            continue
        if m.issym():
            if not stat.S_ISLNK(st.st_mode) or os.readlink(fp) != m.linkname:
                bad.append("symlink " + p)
            continue
        if m.isdir() != stat.S_ISDIR(st.st_mode) or (m.isreg() and not stat.S_ISREG(st.st_mode)):
            bad.append("type " + p)
        if stat.S_IMODE(st.st_mode) != m.mode & 0o7777:
            bad.append("mode " + p)
        if (st.st_uid, st.st_gid) != (m.uid, m.gid):
            bad.append("owner " + p)
        if int(st.st_mtime) != int(m.mtime):
            bad.append("mtime " + p)
        if m.isreg():
            if st.st_size != m.size or sha(open(fp, "rb").read()) != sha(t.extractfile(m).read()):
                bad.append("content " + p)
        if m.islnk():
            if os.lstat(os.path.join(root, m.linkname.lstrip("./"))).st_ino != st.st_ino:
                bad.append("hardlink " + p)
    extra = []
    for d, ds, fs in os.walk(root):
        for x in ds + fs:
            rel = os.path.relpath(os.path.join(d, x), root)
            if rel not in seen and rel != "lost+found":
                extra.append(rel)
    print("root partition: %d archive entries checked, %d mismatches, %d extra" % (n, len(bad), len(extra)))
    if bad or extra:
        for b in (bad + ["extra " + e for e in extra])[:20]:
            print("  " + b)
        fail("root partition differs from debian-rootfs.tar.gz")


if __name__ == "__main__":
    main()
