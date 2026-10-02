# Traps: symptom, cause, fix

Each entry is a failure that is slow to diagnose from its symptom. Read the
heading list first; most save hours.

## Check /mnt/jffs2 before believing anything about the firmware

Applies to the factory Buildroot userspace (Debian does not run `autorun.sh`;
see `talking-to-the-board.md`).

**Symptom:** the transmit attenuation resets itself to 10 dB seconds after a
stream starts, with no userspace write to cause it; no LO change, rate change
or calibration reproduces it; it is absent from the kernel source and survives
reflashing the kernel, the device tree and the bitstream.

**Cause:** a user script on `/mnt/jffs2`, started by `autorun.sh`, polling
`buffer/enable` and applying its own gain two seconds after a stream begins.
`/mnt/jffs2` is the one writable, persistent partition and nothing in a build
touches it, so searching the firmware cannot find it.

**Fix / first step:** read the `Comm:` field of the first stack trace.
`Comm: iio_attr` is a *userspace* process. `sdr_selftest.py --ssh` lists
`autorun.sh` and flags anything under `/mnt/jffs2` that writes radio settings.

## An interrupted build leaves stamps that lie

**Symptom:** a resumed Buildroot build fails with `install: cannot stat
.../mtd-2.1.5/flashcp`, or with hash mismatches on packages that were fine
before.

**Cause:** Buildroot records `.stamp_downloaded` / `.stamp_extracted` /
`.stamp_built` inside each package's build directory, and a build killed
mid-compile leaves stamps claiming unfinished work. Deleting a bad download from
`dl/` without also clearing the build directory produces the mirror-image
failure.

**Fix:** remove the package's build directory so it is fetched and built again.
If several are affected, `rm -rf output/build` and let it redo. If the tree has
also been hand-edited, start from a clean clone: debugging your own damage is
not debugging the repo.

## The measurement is measuring the instrument

Ask "could this be the instrument?" before "is the board broken?". Three
results that look like hardware faults and are not:

- **RX gain "0.65 dB/dB"**: a fit across the AD9361's gain-table transitions.
  See `ad9361-gain-tables.md`.
- **Image rejection moving 15 dB between runs**: measured at whatever gain
  autoranging stopped at, on either side of the LNA transition. Pin the
  operating point.
- **A "300 dBc" spur-free figure**: an FFT bin that is exactly zero, because a
  digital loopback has no noise in it. Cap headline dB figures.

## Verify the edit landed

A `sed` or `str.replace` that matches nothing is not an error, so a stale
string ships silently. Assert the pattern was found, and read back what you
wrote. The same applies to flashing: compare md5sums on the board against the
host before rebooting.

## Background work does not always survive

A `nohup ... &` job can die at a session boundary; `setsid nohup` into its own
session survives. Check with `ps -o sid=` that its session id differs from your
shell's. Write logs somewhere durable: a scratch directory can be cleaned
underneath a running process, losing the log while the job continues blindly.

## When something autonomous changes the radio

Every measurement in the self-test re-reads gain and attenuation, re-asserts
them if they moved, and reports how often that happened. If a number looks
wrong and that counter is non-zero, believe the counter.

## A wrong PACKAGE_PIN is not a build error

Vivado places a port on a ball the board leaves unconnected, meets timing, and
writes a clean bitstream that drives a pad wired to nothing. On this board V11,
W9 and V7 look like plausible header pins and are **no connect** on the
schematic; the real ones are V10, U9, U10, T9. Read the schematic; do not
pattern-match ball names.

- **Ball names do not tell you the bank.** The AD9361 LVDS lines do not share
  bank 13 with the header pins, although their ball names suggest it.
  `get_property IOBANK` in a routed checkpoint is the only authority.
- **An `.xdc` is a restricted Tcl dialect and rejects `if`.** A guarded
  constraint block is discarded whole, and the explanation appears in
  `pluto.runs/*/runme.log`, not the top-level build log. Check the run logs.

## Patches stack, and both obvious "already applied?" tests are wrong

0004, 0005 and 0007 all edit `cf_axi_dds.c`. Once a later one is applied,
`git apply --check --reverse` on an earlier one fails (its context is gone),
so per-patch detection reports a good tree as broken. `git apply --check
a.patch b.patch` tests each against the CURRENT tree, not cumulatively, so a
whole-series check fails the same way. Hence `setup.sh` stamps
`src/.devkit-patches-applied` with a digest of the patch set, and
`build_all.sh` refuses to build without a matching stamp. Generate a new patch
to a stacked file against a reconstructed pre-change copy, not a plain
`git diff`.

`firmware-modern/patches/` stacks the same way (`0004 → 0005 → 0012` and
`0004 → 0015 → 0017`), and `firmware-modern/setup.sh` carries the same stamp.
It also accepts a tree patched **some other way** (by hand, or one commit per
patch while rebasing), which has no stamp and is fine: it checks whether the
LAST patch reverses cleanly, since nothing sits on top of it. Without that,
re-running `setup.sh` on a rebase tree declares the series broken.

## "Verified" must name the exact file

When a check can be satisfied by the wrong artefact, it eventually will be.
`verify_output.sh` checks exactly `pluto.runs/impl_1/system_top.bit`, the file
`build_all.sh` packages, because picking "the smallest `.bit`" lets a stale
compressed bitstream vouch for a fresh one. The flash script waits for
`/proc/uptime` to reset and md5s the card, because the OLD firmware still
answers ssh for a few seconds during shutdown.

## No USB after a reboot, LED blinking: an early-boot RCU hang

Rare (about once in 25 boots on the 6.12 kernel). Symptom: the board
never re-enumerates after a reboot; the USER LED blinks steadily (the kernel's
heartbeat, so the kernel is alive). Cause seen in the stalled boot's journal: a
`call_rcu` WARNING at `kernel/rcu/tree.c:3094` on CPU 0 (its RCU callback list
disabled), then `(mount)` stuck in `synchronize_rcu` and fsck stuck behind a
cgroup lock, so `dev-ttyGS0.device` times out and the gadget never comes up.
Not logind (masked, and seven unmasked boots were clean). Fix: power-cycle,
then save `journalctl -b -1 -k` before the journal rotates. Root cause unknown;
the `DEBUG` serial console is the next tool. Do not run long unattended reboot
loops without a way to power-cycle.
See [docs/debian-root-reference.md, "A rare boot hang"](../../../../docs/debian-root-reference.md#a-rare-boot-hang-rcu-stops-early-in-boot).

## `pgrep -f` and `pkill -f` match the shell that runs them

A waiter loop `while pgrep -f build_all.sh; do sleep 30; done` never exits: its
own command line contains the pattern. `pkill -f "pattern"` kills the shell
issuing it (exit 144). Use PIDs, `pgrep -x <name>` for a process name, or the
bracket trick `pgrep -f "[b]uild_all"`. Also: a shell
`for ...; do [ test ] && echo; done` exits 1 when the LAST iteration's test is
false, so a wrapper that checks exit codes must end such loops with `; true`
and judge the output instead.

**`pkill` does not exist on the Buildroot board** (details in
`talking-to-the-board.md`). If a test concludes "the safety feature did not
fire", first check that the thing it tests against actually happened.

## `Unable to create buffer: -16` is a stale session on the BOARD

`-16` is `EBUSY`. A libiio client that is killed rather than closed leaves its
session open on the board, holding the DMA: the board shows open connections on
port 30431 while the host shows none, and every later transmit allocation is
refused indefinitely. Restarting the client or the host does nothing.
`killall iiod` on the board clears it; so does a reboot.

Do not read a size limit into it: a 4 MB (1048576-sample) transmit buffer
allocates fine as a fresh process's first request, while a 1 MB one is refused
as the same process's second. There is no "1 MB transmit buffer ceiling".

Related: with the digital loopback engaged, allocating a large transmit buffer
can return `-104` (`ECONNRESET`, IIOD reset the session), which leaves the DMA
allocated and produces the `-16` cascade afterwards. Memory is not the cause
(963 MB free, 260 MB of 262 MB CMA free when it happened).

## Transmitting over a wireless host link starves the DAC, and 0015 then mutes

Receiving tolerates a slow link: samples pile up on the board and some are
lost, which prints `O`. Transmitting does not: the converter must be fed in
real time, so a late buffer prints `U`, and **patch 0015 mutes the transmitter
after 250 ms of starvation** and switches the data source to the DDS. Symptom:
a flowgraph that looks like it is still working while nothing is on the air,
and a receiver seeing exactly zero.

Transmit and receive together at 4 MS/s over WiFi gave bursts of 20–40
underflows in 45 s, each beside `Unable to push buffer: Connection timed out`,
while transmit alone at the same rate and buffer gave none. It is intermittent
(the same configuration can run clean an hour later), so it is contention, not
a throughput limit. The defence is buffer DURATION, `buf / samp_rate`, because
that is the stall you can absorb. Lowering the rate helps twice (more slack,
less traffic); raising the buffer helps once.

## A receive buffer as big as the whole capture never returns

`head` for exactly 262144 samples behind a 262144-sample receive buffer hangs
indefinitely; a 65536-sample buffer delivers the same 262144 samples in 1.4 s.
Long-running streams at 262144 are fine; the ask-for-one-bufferful-and-stop
pattern wedges. Any one-shot capture should bound its own wait rather than
trust `tb.wait()`.

## Digital loopback exercises transmit without radiating

`./devkit loopback on` sets the AD9361's `loopback` debugfs attribute to 1, so
transmit samples reach the receiver inside the chip, past the mixers and the
amplifier. Nothing is radiated, so it is the right way to test a
transmit-and-receive flowgraph before making a licensing decision. It does
**not** translate frequency, so set the transmit and receive LO offsets equal;
the analogue attenuator does not apply, so level is set by the digital scale
alone; and a board left in loopback is deaf to its antennas and looks broken.
It survives everything short of a reboot.

## A slow Python block gets your transmitter muted

An embedded block that pegs a core starves the GNU Radio scheduler's other
threads, and on this firmware a starved DAC is a muted transmitter (patch
0015). An `n x order` distance matrix per `work()` call at a megasymbol a
second gave 40 underflows in 45 s where a bare transmit stream gave none
(`examples/lib/evm_meter.py`). Two habits fix it: decide symbols separably where
the constellation allows it (O(n), same answer), and recompute statistics once
per bufferful.

Throttle that recomputation by **samples, not wall time**. A 40 ms clock works
in a live flowgraph and fails offline: a file run finishes inside 40 ms, so the
meter measures once, on the acquisition transient, and reports that for every
symbol (23% EVM on a stream that was 0.3%, flat against changing SNR).

## A .grc that compiles can still be unusable. Open it and LOOK

`grcc` and the editor are different paths, and only the editor draws. A
flowgraph can compile, generate correct Python and run against the board, then
open in GNU Radio Companion as a wall of overlapping text. Nothing automated
catches it because nothing automated renders.

**GRC draws a block's `comment` on the canvas, in full and unwrapped.** It is
not a tooltip. A chooser's option LABELS behave the same way, and so does the
`options` block's comment. `examples/mkgrc.py` asserts the limits: two lines of
46 characters per block comment, eleven of 50 for the flowgraph header, 34 per
option label. Depth goes in the example's README.

Layout rules: put the signal path at the TOP, since GRC opens scrolled to the
top-left; keep variable blocks in a left-hand column with no comments, or their
comments overlap each other.

To look at one without a screen, run it against a virtual display and grab the
root window. Unset `WAYLAND_DISPLAY` first, or GTK ignores `DISPLAY` and opens
on the real session:

```bash
# run from: anywhere on your HOST
Xvfb :99 -screen 0 1920x1200x24 &
env -u WAYLAND_DISPLAY DISPLAY=:99 GDK_BACKEND=x11 gnuradio-companion x.grc &
sleep 45 && DISPLAY=:99 xwd -root -silent > shot.xwd
```

## GRC block ids are not file names, and trailing underscores are stripped

`qtgui_chooser.block.yml` declares `id: variable_qtgui_chooser`;
`import.block.yml` declares `id: import_`, and GRC strips the trailing
underscore when it registers the block, so a flowgraph must say `import`. Get
it wrong and the block contributes nothing: a missing `import math` surfaces as
"name 'math' is not defined" on an unrelated block's parameter. More traps when
hand-writing a `.grc`: the `options` mapping must carry no `name` key (GRC
loads it with `name=''` and the duplicate kills the whole file); a QT Chooser
validates its default against `option0..option4` individually, not against the
`options` list; and an id that any import has already bound is blacklisted, so
a window-selection variable cannot be called `window` (the waterfall sink
imports `gnuradio.fft.window`).

## Sample-rate transitions can fail the AD9361's interface tuning

`ad9361_dig_tune_delay: Tuning TX FAILED!`, with every one of the 16x16 delay
positions marked `#`, can appear after repeated sample-rate changes and leaves
transmit unusable until a reboot. A healthy board passes 157–158 of 256
positions. It is a transition effect, not a property of one rate (2.5 MS/s
provoked it once and ran clean other times), so check `dmesg` when transmit
goes strange rather than avoiding a rate.

## When the board stops answering, the serial console is the instrument

Do not rely on the Debian journal after a hang. Hard power cycling is the only
way out of a hang and it corrupts the journal (`journalctl --verify` reports
"Bad message"), and `journalctl` stops reading at the corruption without saying
so, so the hung boot looks like it ended cleanly at `systemd-journal-flush`.

The serial console keeps everything. `/proc/cmdline` carries
`console=ttyPS0,115200n8` and printk runs at loglevel 7, so a kernel-side hang
prints in full. The DEBUG USB socket gives an FT2232H whose **second** interface
is that UART. Leave a capture running while you work:

```bash
# run from: your PC, with the DEBUG cable connected
ls /dev/serial/by-id/          # ...Digilent...-if01-port0 -> ttyUSB1 is the UART
sudo stty -F /dev/ttyUSB1 115200 raw -echo -crtscts
sudo cat /dev/ttyUSB1 | tee ~/console.log     # leave this running
```

**Never write to `/dev/ttyUSB1` while the cable is unplugged.** `printf '\r\n' >
/dev/ttyUSB1` then creates a **regular file** at that path; udev cannot put the
real device node there when the cable returns, every read returns your own
bytes, and the console looks dead, which reads as "the board is hung". Check the
file type before believing a silent port:

```bash
# run from: your PC
ls -l /dev/ttyUSB1      # crw-rw---- root dialout = real; -rw-r--r-- = a stray file
```

To recover, delete the file and rebind the driver (`udevadm trigger` alone does
not recreate the node):

```bash
# run from: your PC (3-3:1.0 / 3-3:1.1 are this host's FT2232H interfaces; check yours under /sys/bus/usb/drivers/ftdi_sio/)
sudo rm -f /dev/ttyUSB0 /dev/ttyUSB1
for i in 3-3:1.0 3-3:1.1; do echo $i | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind; done
for i in 3-3:1.0 3-3:1.1; do echo $i | sudo tee /sys/bus/usb/drivers/ftdi_sio/bind;   done
```

Two more things that mislead on the console:

- **The board has no RTC**, so `date` reads months out and **every journal
  timestamp is wrong**. `uptime -p` does arithmetic against that clock and can
  report days on a board minutes old: read `/proc/uptime` instead.
- **`auto eth0` with `inet dhcp` makes `networking.service` block about 62 s
  at boot with no Ethernet cable**, waiting for a lease that cannot arrive
  (and blocks shutdown in `ifdown -a`). That is a slow boot, not a hang. The
  Debian overlay's `/etc/network/interfaces` uses `allow-hotplug eth0` to avoid
  it; if a board shows the 62 s wait, check that file.
