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
| **3. In the kernel** | the board's Linux | a kernel build and a patch to maintain | **2m46s** from clean, **6 s** to flash | you need a new sysfs knob, or per-sample timing |
| **4. In the FPGA** | the PL fabric | Vivado, and HDL | **20 min** with `--hdl-only`, **70** from cold | the data rate is too high for anything above |

**The honest default is 1.** One receive channel at the converter's full
61.44 MS/s is **245.8 MB/s**. Measured on this board: **220.0 MB/s** for one
channel and **430.8 MB/s** for two when the samples never leave the board, and a
plateau near **44 MB/s** over gigabit Ethernet with a large buffer
([the measurements](modulation-and-throughput.md)). Anything that fits in that
envelope should start on your PC, where you have Python, matplotlib, a debugger
and no flash cycle.

You move down the table only when the level above genuinely cannot do the job,
and the reason to resist is in the "rebuild loop" column: a change on your PC is
immediate, a kernel change is a couple of minutes, and an HDL change is twenty
minutes before you can even look at it.

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
sdr.rx_destroy_buffer()                   # not optional - see below
```

```bash
# run from: anywhere on your PC
pip install pyadi-iio                     # this is the whole install
```

> **Release the buffer before your script ends, or it dies with a segmentation
> fault.** Leave that last line out and the script above prints your samples and
> then crashes on the way out, exit code 139. Nothing is wrong with your data —
> `x` is complete and correct by then — but a crash on exit fails a test suite,
> a CI job, and anything checking a return code, and it looks alarming enough
> that people assume the capture failed.
>
> A **buffer** here is the block of memory libiio streams samples into. Python
> frees objects in no guaranteed order once the interpreter starts shutting
> down, and if the buffer is freed after the connection it belongs to, libiio
> follows a pointer into memory that has already been handed back. A backtrace
> shows the crash inside `iio_buffer_destroy()`, called from `Py_FinalizeEx` —
> the interpreter's own shutdown.
>
> `rx_destroy_buffer()` (and `tx_destroy_buffer()` after transmitting) frees it
> while everything is still alive, so the ordering never comes up. Calling it is
> harmless if there is no buffer, so there is no reason not to. This is a
> property of the Python binding, not of the board or of your network link, and
> it happens with every version pairing we have tried: the pip `pylibiio` 0.25
> and the Debian/Ubuntu `python3-libiio` 0.23 both do it.

**What to read next, in the order you will want it:**

| | |
|---|---|
| [capturing IQ](capturing-iq.md) | buffer sizes, what the sample format means, and how to not lose samples |
| [`examples/`](../examples/README.md) | three GNU Radio flowgraphs, each one a thing you can watch rather than just run |
| [other SDR tools](other-sdr-tools.md) | GQRX, SDRangel, SDR++, GNU Radio — what works and what needs coaxing |
| [modulation and throughput](modulation-and-throughput.md) | what rate you can actually sustain, measured, and where it stops |
| [transmitter safety](transmitter-safety.md) | **read this before your code transmits** |

> **The one thing that will bite you, and it is not the obvious one.** Setting a
> transmit gain *before* starting the buffer is fine — patch `0005` exists so that
> the unmute does not overwrite it. The trap is writing the **−89.75 dB floor**
> before a stream: both channels at exactly maximum attenuation is how the driver
> recognises "muted", so starting a buffer then restores the *cached* gain and you
> come out **louder than you asked for**, not silent. If you want silence during a
> stream, mute **after** it has started and read the value back. Every tool here
> writes gain after `tx()` and asserts the read-back, which is correct either way.
> [`docs/transmitter-safety.md`](transmitter-safety.md) has the mechanism.

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
# python3-libiio is NOT installed by default - the image ships iiod and the
# libiio-utils command-line tools, but not the Python binding. It is 67 kB.
apt update && apt install -y python3-libiio python3-numpy python3-scipy
cat > /usr/local/bin/my-thing <<'EOF'
#!/usr/bin/env python3
import iio
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
ceiling. They run from **37 to 221 added lines** each, counted on the patch
files.

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

A `uImage` from a clean tree is **2m46s** (recorded, `firmware-modern/README.md`);
an incremental build of one driver file is much less. Flashing it is about six
seconds, and `--kernel-only` is also the rollback — the previous kernel stays on
the card as `uImage.prev`. **Then fold your change into a numbered patch** in
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
| [**Fabric School**](course/index.html) | 54 lessons, or the [189-page PDF](course/Fabric-School.pdf) |
| lessons **4–10** | Verilog from nothing: your first module, clocks and reset, the two assignments and why it matters, the latch trap, width and signedness, fixed point, testbenches |
| lessons **13–18** | **this** design: what the block diagram quietly assumes, valid strobes and the 2R2T trap, the packers, how samples reach memory and back, then a worked insertion line by line |
| lessons **19–23** | **doing it yourself**: packaging your logic as an IP, pins and constraints, driving Vivado and reading what it tells you, crossing clock domains, and registers Linux can read |
| lessons **47–48** | the AD9361 itself, and register by register — the chip sitting in front of your fabric |
| lessons **50–51** | projects in order of difficulty, and the rules worth taping to the wall |

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
./scripts/build_all.sh --hdl-only            # ~20 minutes (70 from cold)
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

1. **Can my PC keep up?** Under ~44 MB/s over Ethernet — **place 1**, and this
   is most projects. Note that 44 MB/s is a *continuous* rate. A **burst** is a
   different question: a single libiio buffer fills at the converter's rate and is
   shipped afterwards. Measured on this board, two channels at 30.72 MS/s: a
   **33 554 432-sample (128 MB) buffer** completes with exit status 0 and delivers
   exactly 134 217 728 bytes, with 891 MB of 1001 still free *during* the run.
   Buffer size is an allocation, so that ceiling is rate-independent — 128 MB is
   about **0.55 s** at the full 245.8 MB/s. That covers far more projects than the
   plateau figure suggests.
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
| transmit is silent | one of four, in order of likelihood: no gain was ever set (`0011` boots at −89.75 dB); the stream starved for 250 ms and `0015` muted it; `tx_disable` is latched; `tx_temp_limit` is armed below the die temperature. `./devkit temps` shows the last two |
