# Using this board in your own project

Every other page here explains a part of the devkit. This one answers the
question they do not: **you have a working board and an idea — where do you put
your code?**

The short answer is that there are four places, they cost wildly different
amounts of effort, and **most projects want the first one**. Working out which
one you need before you start is worth more than any other decision on this
page.

> **New to the board entirely?** Get it talking first — the
> [README](../README.md) gets you from an unopened box to a spectrum on screen,
> and [how it works](how-it-works.md) explains what the files on the SD card
> are. Come back here when `./devkit selftest --ssh` passes.

---

## The four places your code can live

| | Where it runs | What it costs you | Rebuild loop | Reach for it when |
|---|---|---|---|---|
| **1. Host** | your PC, over Ethernet or USB | nothing — pip install and go | seconds | almost always |
| **2. On the board** | the board's two ARM cores | an ssh session | seconds | you need the board standalone, or the data is too big to ship |
| **3. In the kernel** | the board's Linux | a kernel build, ~4 min, and a patch to maintain | ~2 min to flash | you need a new sysfs knob, or per-sample timing |
| **4. In the FPGA** | the PL fabric | Vivado, ~20–70 min per build, and HDL | ~25 min | the data rate is too high for anything above |

**The honest default is 1.** One receive channel at the converter's full
61.44 MS/s is **245.8 MB/s**. Measured on this board: **220.0 MB/s** for one
channel and **430.8 MB/s** for two when the samples never leave the board, and a
plateau near **44 MB/s** over gigabit Ethernet with a large buffer
([the measurements](modulation-and-throughput.md)). Anything that fits in that
envelope should start on your PC, where you have Python, matplotlib, a debugger
and no flash cycle.

You move down the table only when the level above genuinely cannot do the job.
Each step down costs roughly ten times the iteration time of the one above it.

---

## 1. On your PC — start here

The board runs a daemon called `iiod` that serves the radio over the network.
Anything speaking **libiio** can drive it, from any language, with no code on
the board at all.

```python
# run from: anywhere on your PC
import adi
sdr = adi.ad9361("ip:fishball.local")     # or ip:192.168.2.1 over USB
sdr.rx_lo             = 2_400_000_000     # tune to 2.4 GHz
sdr.sample_rate       = 4_000_000
sdr.rx_rf_bandwidth   = 4_000_000
sdr.rx_buffer_size    = 65536
x = sdr.rx()                              # 65536 complex samples
```

```bash
# run from: anywhere on your PC
pip install pyadi-iio                     # this is the whole install
```

**What to read next, in the order you will want it:**

| | |
|---|---|
| [capturing IQ](capturing-iq.md) | buffer sizes, what the sample format means, and how to not lose samples |
| [`examples/`](../examples/README.md) | three GNU Radio flowgraphs, each one a thing you can watch rather than just run |
| [other SDR tools](other-sdr-tools.md) | GQRX, SDRangel, SDR++, GNU Radio — what works and what needs coaxing |
| [modulation and throughput](modulation-and-throughput.md) | what rate you can actually sustain, measured, and where it stops |
| [transmitter safety](transmitter-safety.md) | **read this before your code transmits** |

> **The one thing that will bite you.** Setting transmit attenuation *before*
> starting a buffer does not stick — the driver restores a cached value when the
> stream starts. Set it **after** `sdr.tx(samples)` and read it back. Every tool
> in this repository does it in that order, for that reason.

---

## 2. On the board — when it has to be standalone

The board is a dual-core Cortex-A9 with 1 GB of DDR, running a real Linux. You
can ssh in and run code there.

**Which Linux you get depends on which firmware you flashed**, and for this
purpose the difference is large:

| | `firmware/` (Buildroot) | `firmware-modern/` (Debian) |
|---|---|---|
| installing a package | rebuild the whole image | `apt install python3-numpy` |
| your script survives a reboot | only in `/mnt/jffs2` | yes, it is a real disk |
| Python | a minimal build | the whole of Debian's |
| logs | RAM, gone at reboot | `journalctl`, persistent |

For anything you intend to *develop* on the board, use
[**`firmware-modern/`**](../firmware-modern/README.md). It exists largely for
this reason.

```bash
# run on the board (Debian)
apt update && apt install -y python3-numpy python3-scipy
cat > /usr/local/bin/my-thing <<'EOF'
#!/usr/bin/env python3
import iio                          # libiio's own Python binding, already there
ctx = iio.Context("local:")         # "local:" - no network in the way
print(ctx.devices)
EOF
chmod +x /usr/local/bin/my-thing
```

Use `local:` rather than `ip:` when your code runs on the board — it skips the
network stack entirely and is how you get the ~430 MB/s figure rather than the
~41 MB/s one.

**To make it start at boot**, write a systemd unit, and commit it to
`firmware-modern/debian/overlay/etc/systemd/system/` so the next card you build
has it. There are four shipped units there to copy from. Two things that cost a
morning each:

- **An ordering cycle makes systemd delete your unit**, not fail it. `systemctl
  status` then reports it does not exist, which looks exactly like a typo in the
  filename. `systemd-analyze verify` finds it.
- **`After=` is not `ready`.** A unit ordered after `iiod.service` can still
  start before the thing it needs exists. Wait for the actual file.

---

## 3. In the kernel — a new knob, or per-sample timing

You need this when your project must do something *between* samples, or expose
something as a file. The five transmitter-safety patches in this repository are
all of that shape: a timer that mutes when DMA stops, a latch, a temperature
ceiling. Each is 50–200 lines.

```bash
# run from: the repo root
./firmware-modern/setup.sh                   # once - fetches ADI's 6.12 tree

# run from: firmware-modern/src/linux
$EDITOR drivers/iio/adc/ad9361.c
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- uImage LOADADDR=0x8000 -j$(nproc)
cp arch/arm/boot/uImage ../../output/

# run from: the repo root
FW_OUTPUT=$PWD/firmware-modern/output ./tools/flash.sh --kernel-only
```

First build is under three minutes; an incremental one is well under a minute,
and `--kernel-only` is also the rollback — the previous kernel stays on the card
as `uImage.prev`. **Then fold your change into a numbered patch** in
`firmware-modern/patches/`, or the next clean `setup.sh` loses it — and add an
assertion to the CI workflow, which is how the rest of these stay true.

Read [the kernel page](kernel.md) first, and
[`firmware/README.md`](../firmware/README.md#whats-in-patches) for sixteen
worked examples of exactly this, each with the measurement that justified it.

> **Where you put a flag matters.** Three separate safety bugs in this
> repository were the same bug: a field in `struct ad9361_rf_phy_state`, which
> `ad9361_clear_state()` memsets — so a debugfs `initialize` silently zeroed it.
> Put per-device state in `struct ad9361_rf_phy` instead.

---

## 4. In the FPGA — when the rate is too high for anything else

This is the reason to own this board rather than a USB dongle, and it is also
the most expensive place to work. Reach for it when the input rate is huge and
the output rate is small: a correlator, a decimating filter, a packet detector,
a timestamper. 61.44 M samples per second in, a handful of events out.

**There is a whole course for this**, written against this board, assuming no
prior FPGA knowledge:

| | |
|---|---|
| [**Fabric School**](course/index.html) | 53 lessons, or the [182-page PDF](course/Fabric-School.pdf) |
| lessons **13–18** | Verilog from nothing: what a clock is, what `always` means, why your first design is a state machine |
| lessons **19–23** | **the ones you need for this board**: packaging your logic as an IP, inserting it into the block design, pins and constraints, crossing clock domains, and registers Linux can read |
| lessons **47–48** | timing closure, and reading a Vivado report without guessing |
| lesson **50** | five project ideas sized for this board |

And two worked examples in the tree, both of which you can read as a diff:

- [`firmware/patches/optional/0003`](../firmware/patches/optional/0003-wbfm-channelizer.patch)
  — inserts a frequency shifter and repoints a filter, turning RX0 into an FM
  channelizer ([write-up](wbfm-channelizer.md))
- [`firmware/patches/0006`](../firmware/patches/0006-tx-sample-nibble-to-gpio.patch)
  — routes four bits of every transmit sample to header pins, sample-locked
  ([write-up](tx-gpio-bitmap.md))

```bash
# run from: firmware/
$EDITOR src/hdl/library/my_block/my_block.v
./sim/run_sim.sh                             # ~1 second, against a golden model
rm -rf src/hdl/projects/pluto/pluto.{xpr,cache,gen,hw,ip_user_files,runs,sim,srcs,sdk}
./scripts/build_all.sh --hdl-only            # ~20 minutes
./scripts/verify_output.sh                   # before you flash, not after
cd .. && ./devkit flash --boot-only
```

Three rules that are not negotiable, each of which has cost a build here:

1. **Simulate first.** `run_sim.sh` is one second; synthesis is twenty minutes
   and cannot tell you the logic computes the wrong thing.
2. **Delete the Vivado project before any HDL or block-design change.**
   `build_hdl.tcl` reuses an existing `pluto.xpr` rather than re-running
   `system_bd.tcl`, so your change is *silently ignored* and you flash the old
   bitstream.
3. **Never change the bitstream and the kernel in the same step.** When it
   breaks you will not know which one did it.

Reference material: [the block design, IP by IP](block-design.md) ·
[what the pins are](gpio.md) · [the hardware itself](hardware.md) ·
[building without Vivado](building-without-vivado.md) if you only want to change
software.

---

## Choosing, in one page

Ask these in order, and stop at the first yes.

1. **Can my PC keep up?** Under ~44 MB/s over Ethernet — **place 1**. Note that
   this is a *continuous* rate: a burst that fits in a libiio buffer can be
   captured at the full 245.8 MB/s and shipped afterwards, which covers far more
   projects than the plateau figure suggests. This is most projects.
2. **Must it work with no PC attached, or is the data too big to ship?** —
   **place 2**, on the Debian rootfs.
3. **Do I need a new sysfs file, or to act between samples?** — **place 3**.
4. **Is my input rate genuinely higher than the bus can carry, with a small
   output?** — **place 4**.

And two questions worth asking before any of them:

- **Am I sure the board is healthy?** `./devkit selftest --ssh` measures the
  rails, both die temperatures, the digital interface eye and the receiver, and
  says what is wrong rather than that something is. A day spent debugging your
  code on a damaged board is a day gone.
- **Does my project transmit?** Then read
  [transmitter safety](transmitter-safety.md) first. This board reaches about
  **+19 dBm** out of an SMA, its own receive input is rated **+2.5 dBm**, and a
  loopback without at least 20 dB of attenuation destroys the receiver.

## When it goes wrong

[Troubleshooting](troubleshooting.md) is organised by symptom rather than by
cause, which is how you will arrive at it. The three that catch everyone:

| Symptom | Usually |
|---|---|
| the board behaves unlike its firmware | a script in `/mnt/jffs2` — on Buildroot; check it first, and note nothing runs it on Debian |
| your HDL change did nothing | the Vivado project was reused; delete it and rebuild |
| transmit is silent | you set the attenuation before starting the buffer, not after |
