# The firmware: a pluto-fw v0.38 port (USB + Ethernet)

> **Looking for the build/flash workflow** (installing Vivado, opening the block
> diagram, adding HDL, building, flashing)? That lives in the
> [root README](../README.md). This page covers what is specific to *this*
> firmware: what upstream source it is built from, what was fixed to match the
> real board, and how closely the result has been verified against it.

This is the board's **factory-default firmware** — the one shipped on the SD
card, supporting both USB and Ethernet control.

> **This is not the only firmware target.**
> [`firmware-modern/`](../firmware-modern/README.md) builds **Linux 6.12 LTS**
> from Analog Devices in place of the vendor's 5.15, with the same
> transmitter-safety patches and the same measured RF behaviour. Use that one
> unless you specifically want the factory kernel.
>
> Everything on *this* page is about the factory reconstruction, and the
> byte-for-byte claims below are the reason both targets are kept: they are only
> meaningful against the kernel and device tree a factory board actually runs.
> The modern target makes a different and weaker claim — same *behaviour*,
> measured, not same bytes — and says so.

Upstream: [`Xiaozhang-code-cloud/Fish-Wan-plutosdr-fw-7020-SDR`](https://github.com/Xiaozhang-code-cloud/Fish-Wan-plutosdr-fw-7020-SDR),
a monolithic fork of ADI's `plutosdr-fw` retargeted from the stock ADALM-PLUTO's
XC7Z010-CLG225 to this board's XC7Z020-CLG400, with matching AD9361 pin
constraints.

## Verified against the real board

Every fix in `patches/` was derived by building this exact source and diffing
the result file-by-file against a genuine `SD Card Firmware/` dump from a real
unit:

- **The device tree recompiles byte-for-byte identical** to the factory one
  from patch `0002`. (`firmware-modern/` deliberately gives this up: its tree is
  a ~200-line overlay on ADI's `zynq-pluto-sdr.dtsi` rather than a decompiled
  flat file, and it is audited against the factory tree node by node instead —
  `firmware-modern/verify_dtb.py`.) Patch `0008` then adds `gpio-line-names` — the one
  deliberate departure, so the sample-locked GPIO pins can be found by name
  rather than by arithmetic. Drop `0008` and the `.dtb` is factory-identical
  again, which is the point of keeping it a separate patch.
- **`uEnv.txt`** is content-identical; the only difference is the *order*
  U-Boot's environment hash table dumps variables in, which cannot affect boot
  (variables are looked up by name).
- **The rootfs file list is identical.**
- **`uImage`** builds with an identical kernel `.config` and build banner but is
  not byte-identical: upstream's git history was squashed to a single commit
  dated *after* this board's firmware was built, so some kernel source has
  drifted — not recoverable from the public repo.
- **`BOOT.bin`** inherits the above plus normal Vivado place-and-route
  non-determinism.
- Remaining rootfs size differences (a random password salt, a build-path
  dependent GDB helper, a version-string format depending on submodules) are
  cosmetic.

**Confirmed on real hardware (2026-09-12):** a full `build_all.sh` output,
flashed and booted, initialises the AD9361 cleanly and reports
`fw_version: 95aad-dirty` / `hw_model: FISH Ball PlutoSDR Rev.A (Z7020-AD9361)`
over both the serial console and `iio_info` — see
[Verify your build is actually running](../docs/flashing.md#verify-your-build-is-actually-running).

**Confirmed on real hardware (2026-09-14), current `patches/`:** the TX
safeguard holds across the full cycle — attenuated at boot, the user's gain
preserved while a stream runs, attenuated *and* synthesiser powered down after
it stops, and again on a second stream. Over a 50 dB attenuated loopback,
commanded and applied attenuation matched to 0.01 dB at every point including
0 dB, so full output is unaffected. The persistent serial survives a reboot
while the gadget MAC and interface name stay exactly as before, and SDRangel
opens and streams on both `usb:` and `ip:`.

## What's in `patches/`

`setup.sh` applies all sixteen, in numeric order, to the tree it fetches. Each
one carries its own prose header explaining what it does and what was measured —
`head -40 firmware/patches/0015-*.patch` is often the fastest answer to "why is
this here". Two numbers are missing and neither is a mistake. `0003` became
[`optional/0003`](#optional--not-applied-by-setupsh), the FM channelizer, when it
turned out to change what the radio does rather than fix it. `0010` was written
and then **withdrawn** — review established it had no effect on any reachable
call path and justified itself with a mechanism those call sites cannot produce
([`tools/IDLE-CASES.md`](../tools/IDLE-CASES.md) records the reasoning). Neither
number was reused, because `setup.sh` cannot re-apply a changed patch over its
earlier version and renumbering would have broken every existing checkout.

| | | |
|---|---|---|
| [`0001`](#0001-fishball7020-fixespatch--six-real-fixes) | six real fixes | init scripts, a persistent serial number |
| [`0002`](#0002-add-fishball-devicetreepatch) | the device tree | the reconstruction everything else is measured against |
| [`0004`](#0004-mute-tx-when-no-dma-streampatch) | mute TX with no stream | **safety** — the transmit chain stays biased otherwise |
| [`0005`](#0005-dont-clobber-a-gain-set-before-streamingpatch) | don't clobber a set gain | the unmute used to overwrite what you just asked for |
| [`0006`](#0006-tx-sample-nibble-to-gpiopatch-and-0007-tx-sample-gpio-iio-attributepatch) `0007` | sample nibble to GPIO | the four header pins, and the switch that enables them |
| [`0008`](#0008-name-the-sample-gpio-linespatch) | name those GPIO lines | so `gpiofind sample_gpio0` works |
| [`0009`](#0009-bitmap-flag-cdc-constraint-needs-frompatch) | a constraint that was silently dropped | Vivado said nothing; the crossing went untimed |
| [`0011`](#0011-probe-the-transmitter-at-maximum-attenuationpatch) | probe at full attenuation | **safety** — the driver otherwise comes up at 10 dB |
| [`0012`](#0012-user-led-follows-the-transmitterpatch) | the USER LED follows TX | the LED means "RF can leave the port", not "CPU alive" |
| [`0013`](#0013-stable-mac-and-dhcp-hostnamepatch-and-0014-default-hostname-fishballpatch) `0014` | a stable MAC and a name | a DHCP reservation was impossible before this |
| [`0015`](#0015-mute-the-transmitter-when-the-dac-starvespatch) | mute when the DAC starves | **safety** — `0004`'s guarantee measured false |
| [`0016`](#0016-a-transmit-disable-latch-that-debugfs-cannot-clearpatch) | a TX-disable latch | **safety** — one that `debugfs` cannot switch off |
| [`0017`](#0017-count-transmit-dma-underflowspatch) | count DMA underflows | the hardware reported them and the driver threw them away |
| [`0018`](#0018-refuse-to-transmit-louder-when-the-die-is-hotpatch) | refuse to get louder when hot | **safety**, opt-in — a die-temperature ceiling |
| [`optional/`](#optional--not-applied-by-setupsh) | worked examples | **not** applied; they change what the radio does |

Five of those are marked **safety** and they are not independent: `0004` mutes on
the clean path, `0015` covers the crash and stall paths that `0004` was wrongly
believed to cover, `0011` makes power-on and `debugfs initialize` land on
silence, `0016` is the latch you engage when you do not trust the network, and
`0018` is the thermal ceiling. [`docs/transmitter-safety.md`](../docs/transmitter-safety.md)
is the same story told once, in order, from the operator's side rather than the
patch's.

### `0001-fishball7020-fixes.patch` — six real fixes

**`S23udc`: two hardcoded debug leftovers** — `fw_version=v0.38` and a literal
fake serial — restored to the dynamic runtime lookups the real firmware uses.

With one addition, because the dynamic lookup finds nothing here: it greps
`dmesg` for `SPI-NOR-UniqueID`, which the ADI kernel prints only for Micron
flash, and this board carries a Winbond W25Q128 — so `hw_serial` came out
empty. Anything identifying a Pluto by serial then cannot open it (SDRangel
lists `PlutoSDR0 TBD` and fails with `open serial TBD failed`). The SoC exposes
no unique hardware id at all — no device-tree `serial-number`, no DNA, no efuse
— so the script now mints 16 random bytes once and keeps them in
`/mnt/jffs2/hw_serial`, the board's persistent store.

The USB gadget MACs are `sha1($serial)`, and a changed MAC renames the host's
interface (`enx<mac>`) and breaks any static-IP setup bound to it. So the MACs
are deliberately still seeded from the *original* empty value: interface names
and addresses stay bit-identical, and only `hw_serial` and the USB descriptor
string change.

**The other fixes:** `buildroot/configs/zynq_pluto_defconfig` enables `iperf`
(present on the real board) and sets `CONFIG_BOOTDELAY=3`; the U-Boot configs
get default env values (`maxcpus=2`, `mode=1r1t`), a board-revision GPIO pin
number (`10`→`14`) and a hex-formatting fix (`0x0E00000`→`0xE00000`), all
matched against the real dump; and two `.hash` files are corrected where
Buildroot's git-archive repackaging of pinned commits produces a different tar
byte stream on modern git/tar (`fix_and_retry_buildroot.sh` handles this for
*any* future package hit by the same drift).

> Note: this board's device tree unconditionally sets `adi,2rx-2tx-mode-enable`,
> so the `mode` env var's 1r1t/2r2t switch is a no-op here — **2r2t is always
> active**.

### `0002-add-fishball-devicetree.patch`

Adds `zynq-pluto-sdr-fishball.dts`. None of the three stock device-tree
variants upstream (base/revb/revc) matched the real board — each had at least
one different node — so this file is the real board's own `devicetree.dtb`,
decompiled with `dtc` and confirmed to recompile byte-for-byte identical
through the actual kernel build path.

### `0008-name-the-sample-gpio-lines.patch`

Adds `gpio-line-names` to the Zynq GPIO controller so the four sample-locked
GPIO pins appear as `sample_gpio0`..`sample_gpio3`:

```sh
gpiofind sample_gpio0        # -> gpiochip0 72
gpioget $(gpiofind sample_gpio0)
```

Without it a user has to compute `gpiochip base + 54 + 18` and trust the
result. The controller is 54 MIO lines followed by 64 EMIO, and the property is
positional from line 0, hence the 72 empty placeholders before the four names.

**Two patches change `devicetree.dtb`, and this is one of them** — it adds 152
bytes. `0002` is the device tree itself, the reconstruction everything else is
measured against; on top of that baseline only `0008` (these names) and `0011`
(the probe-time transmit attenuation) alter the compiled `.dtb`. Both are kept
as separate patches for that reason: drop the pair and the device tree is
byte-identical to the factory one again. Do not drop `0011` casually, though —
it is the patch that stops the chip probing at 10 dB attenuation into whatever
is screwed onto the TX port. Verified on the board: `gpiofind` resolves all
four names, and the numeric path (GPIO 978–981 on this 5.15 kernel) still works
exactly as before.

### `0004-mute-tx-when-no-dma-stream.patch`

Mutes the transmit chain whenever no TX DMA buffer is streaming.

The chip keeps that chain biased for as long as the ENSM is in FDD, which it is
from power-on, whether or not anything feeds the DAC. When a TX buffer is torn
down, `cf_axi_dds_buffer_stream.c` only reverts the baseband source to the
silent DDS: the mixer and output stage stay powered, emitting LO leakage and
dissipating power. Measured at boot: ENSM `fdd`, TX LO running, 10 dB of
attenuation.

The fix hooks the buffer lifecycle the driver already has — `preenable` unmutes,
`postdisable` mutes — and calls `ad9361_tx_mute()`, ADI's own exported helper,
present in the tree but called from nowhere. A small wrapper,
`ad9361_tx_lo_powerdown()`, also stops the TX synthesiser on mute: attenuation
is what removes output power, but without this a chain some application powered
up would idle with its oscillator running after that application closed. Order
is kept both ways — signal down before oscillator, oscillator up before signal.
The IIO core runs `postdisable` on teardown **even when the application crashed
or was killed**, which makes this a guarantee rather than best effort.

Two details worth knowing. `ad9361_tx_mute()` restores a *cached* attenuation,
and that cache is only trustworthy once a real mute has filled it — so the
driver never unmutes something it did not mute (`tx_muted`), and deliberately
does **not** mute at probe: the phy has not yet applied
`adi,tx-attenuation-mdB` at that point, the cache would capture the chip's
reset value of 89.75 dB, and every later unmute would restore it, leaving the
transmitter permanently silent (measured: a running stream sat at −89.75 dB
instead of the requested −20). Quieting the board before the first stream is
therefore `S21misc`'s job, attenuation only. And the phy is reached through the
DDS node's existing `clocks` phandle, so **no device tree change is needed**.

### `0005-dont-clobber-a-gain-set-before-streaming.patch`

Restoring the cached attenuation *unconditionally* was itself a trap: setting a
gain and then starting the stream is the obvious order, and the unmute would
overwrite it with the previous transmission's value. The unmute now restores
the cache only when nothing has been set since the mute, so both orders work.

### `0006-tx-sample-nibble-to-gpio.patch` and `0007-tx-sample-gpio-iio-attribute.patch`

Routes the four LSBs of each transmit sample — the bits the 12-bit DAC
discards — to four expansion-header pins, giving digital outputs locked to the
RF sample that carried them. `0006` is the HDL (a ~30-line module, the
block-design tap, the pin constraints); `0007` adds the
`tx_sample_gpio_en` IIO attribute so enabling it is a sysfs write rather than a
raw register poke through debugfs.

The pins are pulled down and the enable bit resets to 0, so the default
behaviour of the radio is unchanged and the four pins remain ordinary EMIO
GPIO. It costs +3 LUTs and +7 flip-flops, no DSPs, no block RAM, and does not
touch the device tree. See [docs/tx-gpio-bitmap.md](../docs/tx-gpio-bitmap.md).

### `0009-bitmap-flag-cdc-constraint-needs-from.patch`

The enable flag crosses from the AXI clock into the AD9361's clock, and
`0006` tells Vivado to limit only the wire length there
(`set_max_delay -datapath_only`), instead of timing it as one clock. But it
named only the end point. `-datapath_only` without `-from` is an error
(`Constraints 18-540`), and in an `.xdc` the error just drops the line. The
build log says nothing. So until this patch, the crossing was timed as an
ordinary 2 ns path and passed on its own. `0009` names both ends. In the routed
design the crossing now reads `MaxDelay Path 4.000ns`, with 2.46 ns to spare.

It is a separate patch rather than an edit to `0006` on purpose. `setup.sh`
cannot re-apply a changed patch over its earlier version, so editing `0006`
would have forced every existing tree back to a fresh clone. `verify-patches`
now checks that every datapath-only delay in the constraints has a `-from`.

### `0011-probe-the-transmitter-at-maximum-attenuation.patch`

`adi,tx-attenuation-mdB` is what the driver writes to **both** transmit
attenuators in `ad9361_setup()`. Upstream it is `10000` — 10 dB — which on a
board reaching about +19 dBm is roughly **+9 dBm at the SMA**, against a receive
port rated +2.5 dBm and whatever the operator has or has not screwed onto TX.
This patch sets it to `89750`: maximum attenuation.

That value is live in two places and both are exposures.

**Every boot.** The driver probes, applies 10 dB, and the transmitter sits there
until `S21misc`'s `tx_quiesce` writes −89.75 dB over it. The window is short and
has never been measured from outside — the board cannot observe its own boot —
but it is real, and it is the one moment an unterminated TX port is hot without
anyone having asked for anything.

**Until somebody notices.** `echo 1 > /sys/kernel/debug/iio/iio:device0/initialize`
re-runs `ad9361_setup()`, which re-applies the property to both channels. From a
muted −89.75 dB that is a **≈79.75 dB raise** with no unmute, no buffer enable
and nothing in the log. `0005` does not help: this is not an `ad9361_tx_mute()`
unmute and never touches the cached attenuation.

The cost is that a transmitter never given a gain now stays silent instead of
emitting at 10 dB. Every tool in this repo already sets an attenuation before
transmitting, because `tx_quiesce` has made that necessary since `0004`.
`verify-patches.yml` asserts the constant `<0x15E96>` in the DTS, because this is
the kind of value a careless device-tree edit silently reverts.

### `0012-user-led-follows-the-transmitter.patch`

The USER LED runs the kernel's heartbeat trigger, which tells you the CPU is
alive and nothing else. On a board that reaches +19 dBm, the more useful thing
for it to say is **whether RF can leave the port**.

This registers a `tx-active` LED trigger driven from `ad9361_set_tx_atten()` —
the single point every attenuation change passes through, the kernel's own mute
on DMA teardown and a plain sysfs write alike. Lit whenever either chain is out
of full attenuation; dark when both sit at the −89.75 dB floor.

Hooking the attenuator rather than the DMA buffer is deliberate: attenuation can
be raised with no buffer open at all, so a stream-only indicator would sit dark
while LO leakage left the SMA. Measured: TX1 alone, TX2 alone, both, and a
running stream each light it; returning to the floor puts it out.

The LED hangs off PS MIO pin 0, so it cannot be reached from the PL and this has
to be software — [`docs/user-led.md`](../docs/user-led.md). The trigger is
selected in `S21misc` rather than the device tree, so the `.dtb` stays
byte-identical to the factory one. `fw_setenv tx_led 0` keeps the heartbeat.

### `0013-stable-mac-and-dhcp-hostname.patch` and `0014-default-hostname-fishball.patch`

Two things a router needs before it can show this board as anything but a hex
string, neither of which the stock firmware does.

**The MAC was random on every boot.** The device tree carries no
`local-mac-address`, so the `macb` driver logs `invalid hw address, using random`
and `eth0` comes up as a different locally-administered address each time. The
router sees a brand-new device at every reboot and **a DHCP reservation cannot be
made at all** — observed directly, two consecutive boots taking
`192.168.129.139` then `.140`. U-Boot already holds a MAC in `ethaddr` and uses
it for its own networking, so `eth0` is now pinned to the same one and the board
keeps one identity from bootloader to Linux.

**Nothing said who we were.** `udhcpc` ran with no hostname, so DHCP option 12
was absent. busybox `ifupdown` turns a `hostname` line in the interface stanza
into `udhcpc -x hostname:` and a `hwaddress` line into an `ip link set addr`
before the interface comes up, so both fixes are two lines in the file
`S40network` already generates.

`0014` shortens the default from `Fishball7020` to **`fishball`**, so the board
answers to `fishball.local` without shift-key gymnastics. It is a separate patch
only because `0013` had already been applied to trees in the wild. Either way the
name stays per-board: `./devkit net name <host>` overrides it without a rebuild,
and setting it back to `pluto` restores compatibility with tooling that expects
`pluto.local`.

> On the Debian rootfs these two do nothing — `/etc/network/interfaces` is a
> fixed file there and `hostnamectl` sets the name. `firmware-modern/debian/`
> reimplements both behaviours for the same measured reasons, and `./devkit net`
> now detects which rootfs it is talking to rather than writing a variable
> nothing reads.

### `0015-mute-the-transmitter-when-the-dac-starves.patch`

**`0004` described itself as a guarantee, and it measured false.** It mutes from
the buffer's `postdisable` hook on the grounds that the IIO core runs
`postdisable` even when the application crashed or was killed. It does not:
[`tools/IDLE-CASES.md`](../tools/IDLE-CASES.md) case B is `kill -9` on a **local**
process feeding a TX buffer, after which `buffer/enable` still reads `1`, the
mute never fires, and the transmitter stays live indefinitely. Through a 20 dB
loop the port read **−46.7 dBFS against −59.3 dBFS muted** — 12.6 dB hotter with
both the writer and its feeder confirmed gone. Case C, a client that stalls
without dying, was never covered at all.

The fix is to stop keying off events. Closing, killing and crashing are events,
and an event can be missed. *"No DMA block has arrived for N milliseconds"* is a
**state**, and a state cannot be. One timer closes both cases:
`dds_buffer_submit_block()` re-arms it on every block, `preenable` arms it so a
buffer enabled and never fed is covered too, and `postdisable` cancels it so the
clean path is unchanged. It is a workqueue rather than a timer because muting
talks to the AD9361 over SPI, and that sleeps.

```sh
# run on the board — milliseconds, 0 disables, values under 20 are refused
cat /sys/bus/iio/devices/iio:deviceN/tx_starve_timeout_ms    # default 250
```

Values under 20 ms are refused because this board's network path already
delivers in bursts with gaps, and a timeout inside that would mute a healthy
stream and present as a mysterious dropout. **Cyclic streams are exempt**: the
hardware repeats one submitted block forever, so silence on the submission path
is the feature working. They get a separate, opt-in backstop in
`tx_cyclic_timeout_ms`. Measured mute time: **0.26–0.27 s**, on 5.15 and 6.12
alike.

### `0016-a-transmit-disable-latch-that-debugfs-cannot-clear.patch`

`iiod` listens on TCP 30431 with **no authentication of any kind**, so anyone who
can reach the board can tune, receive and transmit. Two of those routes do not
even look like transmitting: `initialize` in debugfs re-applies the device tree's
attenuation to both channels, and `bist_tone` injects a tone at the *transmit*
data port, so it reaches the DAC and the PA with nothing muting it.

This adds one latch, off by default:

```sh
# run on the board
echo 1 > /sys/bus/iio/devices/iio:device0/tx_disable
```

Enforcement is inside `ad9361_set_tx_atten()` — the same choke point `0012` uses.
It **clamps rather than refuses**, because several callers treat a failure there
as fatal and would leave the chain half-configured, and because the safe outcome
is silence rather than an error. `bist_tone` mode 1 is refused separately, since a
digital injection never touches the attenuator.

**Where the flag lives is the whole patch.** The obvious home is
`ad9361_rf_phy_state`, next to `tx1_atten_cached`. That is wrong, and hardware
said so: `ad9361_clear_state()` does `memset(st, 0, sizeof(*st))` and debugfs
`initialize` calls it on the way to `ad9361_setup()`. Measured with the flag in
there — engage the latch, poke `initialize`, and the transmitter came back at
−10 dB while `tx_disable` still read `1`. A latch the surface it defends against
can switch off with one `echo` is not a latch. So it lives in
`struct ad9361_rf_phy`, which `clear_state()` does not touch. `verify-patches.yml`
asserts that structurally, because it is not the kind of thing a reviewer spots.

| asked for | attenuation after | |
|---|---|---|
| boot default | −89.75 dB | `0011`'s device tree |
| latch on | −89.75 dB | |
| sysfs write −20 dB | −89.75 dB | refused to rise |
| debugfs `initialize` | −89.75 dB | both channels, latch still `1` |
| `bist_tone` mode 1 | refused | |
| `bist_tone` mode 2 | accepted | receive-side, unaffected |
| latch off, set −30 dB | −30 dB | releases cleanly |

### `0017-count-transmit-dma-underflows.patch`

The DAC core reports underflow and overflow in `ADI_REG_VDMA_STATUS`. The driver
wrote the bits back to clear them at `preenable` and otherwise **ignored them**;
there is a commented-out `dev_warn` from 2014 where the check used to be. So the
only way to know whether a transmission was clean was to receive it and look at
the spectrum — which is exactly what
[`docs/modulation-and-throughput.md`](../docs/modulation-and-throughput.md) had to
do to establish that drops were discrete packets rather than continuous
degradation.

The bits are sticky and read-to-clear, so they answer *"did it happen"* rather
than *"how often"*. Sampling once per submitted block and accumulating turns them
into counts:

```sh
# run on the board — write anything to either to zero it
cat /sys/bus/iio/devices/iio:deviceN/tx_dma_underflow_count
cat /sys/bus/iio/devices/iio:deviceN/tx_dma_overflow_count
```

Measured: a 131 072-sample stream fed from a pipe recorded **2** underflows — a
short stall at stream start that a spectrum would have had to infer.

### `0018-refuse-to-transmit-louder-when-the-die-is-hot.patch`

The board has reported its own die temperature all along and nothing ever acted
on it. A transmitter is the one part here that heats itself, and the PGA-102+
sits next to the AD9361.

```sh
# run on the board — millidegrees C, 0 disables (the default)
echo 60000 > /sys/bus/iio/devices/iio:device0/tx_temp_limit
```

Above that die temperature the driver **refuses to lower the attenuation**. Off
by default, because the right threshold depends on the enclosure and the duty
cycle and any value chosen here would be wrong for somebody —
`./devkit temps` prints the knob's state and suggests one. It is checked in
`ad9361_set_tx_atten()`, the same choke point as `0016`, and **only** when
something asks to be louder than fully muted, so the cost is one AuxADC read per
gain change rather than anything per-sample. **Muting is never blocked by it**:
the failure direction is silence.

Measured at a real die temperature of 48.246 C:

| limit | asked for | got |
|---|---|---|
| 43.246 C | −30 dB | **−89.75 dB, refused** (`dmesg`: *"die at 48.246 C is over the 43.246 C transmit limit - staying muted"*) |
| 68.246 C | −30 dB | −30 dB, allowed |

This also makes a **safe way to test transmit code with an antenna fitted**: arm
the limit *below* the current die temperature and every request to get louder is
refused and logged, while muting still works. Confirm the gate is live with an
explicit write first — a silent log proves nothing.

### `optional/` — not applied by `setup.sh`

Worked examples that *change what the radio does* rather than fixing it, so
they live apart and `setup.sh` leaves them alone. Apply by hand:
`(cd src && git apply ../patches/optional/<name>.patch)`.

- **`0003-wbfm-channelizer.patch`** — a worked example of custom DSP in the
  AD9361 chain. Adds `ad_fs4_ddc.v` (an Fs/4 shifter) ahead of
  `rx_fir_decimator` and repoints that filter at narrow-band FM coefficients,
  turning RX channel 0 into a single-station channelizer. See
  [docs/wbfm-channelizer.md](../docs/wbfm-channelizer.md).

- **`0004-filter-both-receive-channels.patch`** — fixes something real, and is
  optional anyway because it costs FPGA resources. Upstream routes channel 0
  through `rx_fir_decimator` and sends channel 1 straight to `cpack`. Since
  `cpack` captures every enabled channel on channel 0's valid, the moment
  decimation is engaged **channel 1 is sampled at one eighth rate with no
  anti-alias filter of its own** — everything outside ±Fs/16 folds onto it — and
  it is offset from channel 0 by the filter's group delay. Harmless on the 1R1T
  boards this block design also targets, where there is no channel 1; on a 2R2T
  board it makes the second receiver unusable whenever the fabric decimator is
  on. Measured TX2A → 20 dB → RX2A at 61.44 MSPS with the decimator engaged and
  a tone at 10 MHz, outside the decimated ±3.84 MHz window: **before**, channel 1
  showed an alias at +2.320 MHz (10 − 7.68) at 70.1 dB; **after**, no alias, the
  strongest in-band bin being DC at −2.8 dB. The cost is **94 DSP48s instead of
  72** and 12 521 LUTs instead of 11 896, closing timing at +0.215 ns rather than
  +0.205 ns — the figures in
  [`docs/block-design.md`](../docs/block-design.md) label both builds for exactly
  this reason. Full write-up, including the spectra:
  [`docs/both-receive-channels.md`](../docs/both-receive-channels.md).

Neither touches the device tree, kernel or bootloader, so every provenance claim
above still holds; drop the patch to get the stock datapath back.

## Build system internals

`scripts/build_all.sh` deliberately does **not** call upstream's top-level
`Makefile` — it reimplements the steps so that Vivado's `settings64.sh`
(sourced for the HDL/FSBL/packaging steps only) never leaks its bundled
cross-toolchain `PATH` entries into the u-boot/kernel/buildroot steps, which
broke the kernel build the first time this was tried (see
[Troubleshooting](../docs/troubleshooting.md)).

It does replicate one upstream step exactly: writing
`buildroot/board/pluto/VERSIONS` and running Buildroot's `legal-info` to
generate `msd/LICENSE.html`, which `post-build.sh` needs to finish the rootfs.
That file is not one of the five SD-card outputs, but its absence aborts the
Buildroot run before `rootfs.cpio.gz` is ever produced.

See `scripts/build_all.sh` itself for the exact current sequence — it is short
and directly readable.
