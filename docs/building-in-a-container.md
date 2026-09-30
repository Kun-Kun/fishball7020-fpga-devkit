# Building in a container

**This is the recommended way to build this firmware.** A container is an
isolated, pinned Linux userspace that runs on your own kernel, so the build
sees the same libraries on every machine.

Vivado 2022.2 is pinned to this project, because a toolchain change changes the
bitstream. It supports Ubuntu 18.04, 20.04 and 22.04 and nothing newer, and its
installer will not run on a newer host either. `./devkit container` runs the
build (and, if needed, the Vivado installer) in an Ubuntu 22.04 image, so your
host OS does not matter.

## Quick start

```bash
# run from: the repo root
./devkit container build-image      # once, ~3 min
./devkit container doctor           # the same checks as ./devkit doctor, inside
./devkit container setup            # clone upstream source + apply patches   (~5 min)
./devkit container build            # everything                           (45-90 min)

# after that first full build, the fast loop for an HDL change:
./devkit container build --hdl-only #                                       (~20 min)
```

No Vivado yet? Install it first: [Installing Vivado in the first
place](#installing-vivado-in-the-first-place).

## Same output as a host build

The container and a host build produce the same files. What that rests on, and
how to check it on your own machine (build once each way, then compare
`md5sum firmware/output/*`):

| | rebuilt by `--hdl-only`? | host vs container |
|---|---|---|
| `BOOT.bin` | **yes**: synthesis, implementation, FSBL, `bootgen` | **identical** |
| `uramdisk.image.gz` | **yes**: `mkimage` re-wraps it every build | **identical** |
| `uImage`, `devicetree.dtb`, `uEnv.txt` | no, reused from the full build | identical |

- For the current default design, `BOOT.bin` is `3fb710d8f990cec8f14d5ca61ca2ddb7`
  from a host build, from the container, and from a container whose Vivado was
  installed by `./devkit container install` into a directory the host never
  used (DSP48s 94/220, Slice LUTs 12521, WNS 0.215 ns).
- Routing utilisation matches to five decimals between host and container
  (6.54675 % vertical, 9.82488 % horizontal).
- The comparison also holds from a fresh clone with the Vivado project deleted
  first, so synthesis and implementation run from scratch in both. That run
  used the channel-0-only design (`STOCK_RX_FILTER=1`'s datapath: DSP48s 72/220,
  WNS +0.205 ns over 48 263 endpoints), where `BOOT.bin` is `b2de45be…` both ways.
- **All five SD-card files are reproducible.** `mkimage` re-wraps the root
  filesystem on every build, including `--hdl-only`, and writes a timestamp into
  U-Boot's 64-byte image header. `build_all.sh` sets `SOURCE_DATE_EPOCH` to the
  root filesystem's own modification time, so the header is stable. An
  externally set `SOURCE_DATE_EPOCH` wins.

## Installing Vivado in the first place

The container exists because your host may be too new to run Vivado 2022.2.
The Xilinx installer is the *same* Java/GTK application with the same
requirements, so on such a host it cannot run the installer either. The
installer therefore runs in the container too, writing to the host:

```bash
# run from: the repo root
# AMD put the installer behind an account login, so download it yourself first:
#   https://www.xilinx.com/support/download.html  ->  Vivado 2022.2  ->  Linux Self Extracting Web Installer

# Rootless podman maps the container's root to YOUR user, so the target must be
# yours: a root-owned /tools/Xilinx cannot be written even from "root" inside.
sudo mkdir -p /tools/Xilinx && sudo chown "$USER" /tools/Xilinx

./devkit container install ~/Downloads/Xilinx_Unified_2022.2_1014_8888_Lin64.bin
```

This mounts `/tools/Xilinx` **read-write** (the one time it is not read-only),
passes your display through, and runs the installer's own GUI. Answer it as
[building.md](building.md#install-vivado-20222) describes: choose **Vivado**,
select only **Zynq-7000** under device families (~130 GB down to ~30 GB), and
keep the path `/tools/Xilinx`.

It is the web installer, so it needs your AMD account during the run and
downloads the content itself. Budget an hour and the disk space.

Afterwards every other command mounts `/tools/Xilinx` read-only, and the host
never needs to run a Xilinx binary.

### "Extraction failed." from the installer

`./devkit container install` handles this, but the message is misleading if
you run the installer another way. The self-extracting archive trips its own
signal trap on the way out:

```
Uncompressing Xilinx Installer.........Extraction failed.
Signal caught, cleaning up
```

It exits with status 143 having extracted all 720 MB correctly, so a script with
`set -e` stops there and never launches the installer. The install step checks
that an executable `xsetup` was produced instead of trusting the exit status.

The same message also appears when extraction really does fail, in two
situations: unpacking relative to a read-only directory (the one holding the
installer is mounted read-only), and unpacking onto the container's own overlay
filesystem, which rootless podman mounts with `userxattr`. The installer's work
directory is a bind mount for both reasons.

## What is and is not in the image

- **Vivado is not in the image.** `/tools/Xilinx` is bind-mounted read-only, so
  the image is about 1.4 GB rather than 45, and the toolchain you test is the
  one you already have. The image pins the userspace around it: glibc, the X
  libraries, and the packages `doctor.sh` checks for.
- `gcc-arm-none-eabi` and `libnewlib-arm-none-eabi` (about 500 MB) are in it,
  for the boot loader. No Vitis, Xvfb, GTK3, WebKit or SWT: nothing in the build
  needs them. GTK2 is there, for Vivado's GUI.
- **The repo is mounted at its own absolute path**, not at `/work`. Vivado
  stores absolute paths inside `pluto.xpr`, so a project created on the host and
  one created in the container are interchangeable only if the path matches.
- **Output files are owned by you.** Rootless podman maps the container's root
  to the invoking user; Docker has no such mapping and is passed `--user`.

## Reaching the board from inside

The container can talk to the board: TCP to `iiod` on 30431 and to ssh on 22
both work on the default network. What it cannot do by itself is resolve the
board's name.

`fishball.local` is an **mDNS** name: a name the board announces on the local
network itself, with no DNS server involved. Resolving one needs an mDNS
resolver on the asking machine, and the image has none (its
`/etc/nsswitch.conf` is `hosts: files dns`, with no `mdns4_minimal` and no
avahi). Left alone, `tools/board_addr.py` would fall through to its last
candidate, the USB gadget address `192.168.2.1`, which is wrong when the board
is on Ethernet.

So `tools/container/run.sh` resolves the name on the **host**, where mDNS works,
and passes the answer in: the address as `BOARD`, plus `--add-host` so the name
keeps working for `ssh` and `scp` inside `./devkit container shell`. A `BOARD`
you set yourself is forwarded untouched.

The image has no `ping`. `doctor` and `status` use
`tools/board_addr.py --check` instead, which needs no ICMP and makes each
service identify itself (`iiod` answers `VERSION`, dropbear names itself in its
SSH banner), so something else holding an open port is not mistaken for the
board.

**Build in the container; flash from the host.** `flash`, `selftest`,
`gpio-check` and `verify --board` are host commands.

## Vivado dies in synthesis with a heap error

```
tcmalloc: large alloc 115875935977472 bytes == (nil)
realloc(): invalid pointer
Abnormal program termination (6)
```

**Cause.** A 115 TB allocation is an integer underflow, and the stack names
neither culprit near the top. Vivado's licence manager (`libXil_lmgr11.so`)
`dlopen`s `libudev.so.1` and enumerates **every device on the machine** to
fingerprint the host for WebTalk registration. By then Vivado's bundled
**tcmalloc has replaced malloc process-wide**, while libudev still frees through
glibc. The two allocators disagree and glibc's heap checker kills the process.
On Ubuntu 20.04 the same cause shows as a `SIGSEGV` in `malloc_usable_size`
instead.

**Fix (already applied by `./devkit container`).** `tools/container/udev-stub.c`
answers that enumeration with an empty list. It allocates and frees nothing, so
the allocators never meet, and the licence manager falls back to its other
host-id sources. Only the fingerprint changes; synthesis, implementation and
the bitstream are untouched, and the XC7Z020 is a WebPACK part that needs no
licence anyway.

**Do not** switch off glibc's heap checker instead: that hides real heap
corruption inside the tool that produces your bitstream. Mounting `/run/udev`,
`config_webtalk -user off` and an Ubuntu 20.04 base do not fix it.

## Why 22.04 and not 20.04

[UG973](https://docs.amd.com/r/2022.2-English/ug973-vivado-release-notes-install-license/Supported-Operating-Systems)
lists 18.04, 20.04 **and** 22.04 for Vivado 2022.2. 20.04 is the newest Ubuntu
that still ships `libtinfo5`, `libncurses5` and `libssl1.1`, so Vivado's
runtime libraries would come from the archive instead of `tools/legacy-libs/`.
The image uses 22.04 anyway:

- The udev crash above happens on 20.04 too.
- 22.04 is equally supported and is the host release this Vivado runs on.
- `tools/legacy-libs/` was extracted on 22.04. Those copies need `GLIBC_2.33`
  and cannot load on 20.04 at all. `env-vivado.sh` therefore adds them only
  where the distribution has no `libtinfo.so.5` of its own; forcing them onto an
  older release fails with `librdi_commontasks.so: GLIBC_2.33 not found`, an
  error naming a library that is not the problem.

## Other operating systems

Only Linux hosts are tested.

| | |
|---|---|
| **Any Linux** | Yes. The container supplies the userspace, your kernel runs it natively. This is the tested case. |
| **Windows** | Very likely, through WSL2 (a real Linux kernel on x86-64). The simpler route is to skip containers and run the devkit directly in WSL2 Ubuntu, with WSLg for the block-design GUI. Keep the checkout inside the WSL2 filesystem, never on `/mnt/c/`: builds across that boundary are very slow, and case sensitivity and POSIX permissions do not survive it, which Vivado's project files depend on. Reaching the board over WSL2's default NAT may need mirrored networking. |
| **macOS, Intel** | Plausible. The Linux VM is x86-64, so the container runs natively in it. You would need XQuartz for the GUI and room for 44 GB inside the VM. |
| **macOS, Apple Silicon** | Realistically no. The VM is ARM64 and Vivado is x86-64 only. Rosetta can translate x86-64 Linux binaries, but Vivado is a large threaded application with its own JVM and tcmalloc, the kind of software that breaks under translation (the udev crash above shows how sensitive its allocator is). |

Flashing is unaffected either way: `./devkit flash` talks to the board over the
network from the host, and never needs the container.
