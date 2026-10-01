# SDR++ with both receivers (Arch)

[SDR++](https://www.sdrpp.org/)'s PlutoSDR source only ever reads RX1. This
directory builds SDR++ as an Arch package with a patch that adds an **RX Port**
selector (RX1 or RX2) to that source, so either of this board's receivers can be
used.

## Quick start

```bash
# run from: tools/sdrpp/
makepkg -f                                   # builds sdrpp-git-…-2-x86_64.pkg.tar.zst
sudo pacman -U sdrpp-git-*-x86_64.pkg.tar.zst
```

Then in SDR++: choose the PlutoSDR source, pick **RX Port**, and press play. The
selector is greyed out while streaming, like the device and sample-rate menus;
stop, switch, start. The choice is saved per device.

Build on a disk with a few GB free, not on a small `/tmp`: `makepkg` packages
an empty `libsdrpp_core.so` if stripping runs out of space, and only says so in
the middle of its log.

## What the patch changes

| | RX1 | RX2 |
|---|---|---|
| gain and gain mode (`ad9361-phy`) | `voltage0` | `voltage1` |
| I/Q samples (`cf-ad9361-lpc`) | `voltage0`, `voltage1` | `voltage2`, `voltage3` |

Sample rate, filter, RF bandwidth and port selection are shared by both receivers
and stay on RX1's channel. On a one-receiver Pluto, selecting RX2 logs an error
and does not start.

## What the PKGBUILD is

The AUR `sdrpp-git` recipe, pinned to commit `8c9f5ee8`, with the Airspy and
AirspyHF sources turned off and the PortAudio sink on, so it builds with only the
libraries listed in `makedepends` (HackRF, RTL-SDR, libiio, libad9361, RtAudio,
PortAudio). It installs the same 26 plugins as an unpatched build of that
commit.
