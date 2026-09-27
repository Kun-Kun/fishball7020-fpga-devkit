# Stock against both-RX-filtered, measured on one board

**Why this exists.** For a while this board ran the **both-receive-channels-filtered**
bitstream (`optional/0004`, 94 DSP48s, WNS +0.215 ns) while every figure in
`docs/` described the **stock** build (72 DSP48s, +0.205 ns). That was found on
2026-09-27, the board was put back on v1.5's stock `BOOT.bin`
(`sha256 7c44f358…`, verified against v1.5's own `SHA256SUMS`), and both states
were measured either side of the swap. Kernel, device tree and rootfs were held
constant; only `BOOT.bin` changed.

## The finding: the self-test cannot tell them apart

| field | filtered | stock | |
|---|---|---|---|
| digital interface eye | **157** | **157** | identical |
| digital loopback error | 0.0 dB | 0.0 dB | identical |
| TX power, capped estimate | 19.0 dBm | 19.0 dBm | identical |
| image rejection | 76.6 dBc | 66.6 dBc | within the documented ±10 dB run-to-run |
| image rejection, as found | 53.9 dBc | 52.9 dBc | |
| TX mute depth | 69.0 dB | 75.7 dB | floor-limited, so this tracks the noise floor |
| DC offset | −78.7 dBFS | −86.3 dBFS | |
| system gain | −0.25 dB | −0.49 dB | |
| implied pad | 20.4 dB | 20.6 dB | the 20 dB pad, both times |
| RX gain range | 44.6 dB | 44.4 dB | |
| AD9361 / Zynq die | 49.1 / 70.9 C | 47.4 / 69.6 C | cooler, minutes apart |

`32 passed, 1 warning, 0 failed` both times; `./devkit gpio-check` **PASS** both
times. Every stable field is identical and every field that moved is one the
documentation already marks as varying run to run.

**That is not a null result, it is the explanation.**
`tools/selftest/sdr_selftest.py:258` keeps the FPGA decimator **deliberately
bypassed** — it is a channel filter, and the self-test wants the full band. But
`optional/0004` only does anything *when the decimator is engaged*: it gives RX1
its own anti-alias filter. So the self-test structurally cannot distinguish the
two bitstreams, which is exactly why the board could run the wrong one for weeks
with 32 tests passing.

If you want to tell them apart, engage the decimator and look at RX1 — the
before/after spectra in [`docs/both-receive-channels.md`](../../docs/both-receive-channels.md)
are the measurement that does it (an alias at +2.320 MHz at 70.1 dB, or none).

**A gap worth knowing rather than fixing blindly:** adding a decimator-engaged
check to the self-test would catch this class, but it would also make the
self-test's pass criteria depend on which optional patches are applied. That is a
trade-off, not an oversight.

## Also confirmed

`./devkit uboot-contract` was **identical to its baseline** across the swap —
which is what should happen, since the U-Boot environment lives in QSPI and a
`BOOT.bin` swap does not touch it. Useful as a check on the check.

`fw_version` read `v2.0-9-g5ae29d94-dirty` after the reboot rather than
`debian-13`, confirming `/opt/VERSIONS` survives a power cycle as an ordinary file
on the ext4 root.
