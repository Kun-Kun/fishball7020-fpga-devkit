# Controlling the USER LED

How to use the board's one programmable LED: what it shows by default, how to
drive it from Linux or your own program, how to change its boot-time
behaviour, and what to use instead if you want an LED driven by FPGA logic.

The board has three LEDs between the `USB2.0` and `DEBUG` ports:

| LED | Driven by | Can you control it? |
|---|---|---|
| `PWR` | Power rail | No: hardwired |
| `DONE` | The FPGA's own configuration logic | No: it goes high when the bitstream loads |
| `USER` | Linux, through a PS GPIO pin | **Yes**: this page |

## How it is wired

From the board's device tree:

```dts
// in firmware/src/linux/arch/arm/boot/dts/zynq-pluto-sdr-fishball.dts (excerpt)
leds {
    compatible = "gpio-leds";
    led0 {
        label = "led0:green";
        gpios = <0x09 0x00 0x00>;          /* controller, pin 0, active high */
        linux,default-trigger = "heartbeat";
    };
};
```

Phandle `0x09` resolves to `gpio@e000a000`, `xlnx,zynq-gpio-1.0`, the **PS**
(processing system, the ARM side) GPIO controller. So the LED hangs off **MIO
pin 0 on the ARM side**. The consequence:

> **You cannot drive this LED from your HDL.** MIO pins belong to the
> Processing System and are not routed into the Programmable Logic. It does
> not appear in `system_top.v` or `system_constr.xdc`, and no amount of
> block-design work will connect it. Driving it is a *software* job.

A *trigger* is a kernel rule that drives an LED automatically. The
`linux,default-trigger = "heartbeat"` line is what the *factory* firmware uses:
a steady blink while the kernel runs. This repo's builds leave the device tree
as it is and select a different trigger at boot; that is the next section.

## What it does by default here: it follows the transmitter

On a board that reaches about **+19 dBm**, a light that shows **whether RF can
leave the port** is more useful than one that shows the CPU is alive. So these
builds ship a kernel LED trigger called `tx-active`, selected at boot by
whichever init the rootfs has:
[`S21misc`](../firmware/patches/0012-user-led-follows-the-transmitter.patch) on
Buildroot, `fishball-identity` (run by `fishball-identity.service`) on Debian.
Both honour `fw_setenv tx_led 0` to keep the heartbeat instead, and both check
that the trigger exists before selecting it, so an older kernel without patch
`0012` degrades to the heartbeat rather than failing to boot:

> **Lit** whenever either transmit chain is out of full attenuation.
> **Dark** when both sit at the −89.75 dB mute floor.

The trigger is driven from `ad9361_set_tx_atten()` in the AD9361 driver, the
one point every attenuation change passes through, whether that is the kernel's
own mute when a DMA stream is torn down (patches `0004`/`0005`) or a plain
sysfs write. There is no polling loop.

**Why the attenuator and not the DMA buffer.** Attenuation can be raised with
no buffer open at all: the driver accepts it and drives the real attenuator, so
a stream-only indicator would sit dark while the LO (local oscillator) leaks
out of the SMA. The trade is the mirror image: a DMA stream running into a
fully attenuated chain leaves the LED dark, because nothing is getting out.
On hardware:

| State | LED |
|---|---|
| both channels muted, no buffer | dark |
| TX1 raised, no buffer | **lit** |
| TX2 raised, no buffer | **lit** |
| both raised | **lit** |
| gain set, then a DMA stream running | **lit** |
| DMA stream running, both channels still muted | dark |
| stream ends, kernel re-mutes | dark |

**To opt out** and keep the heartbeat, set a U-Boot variable and reboot:

```bash
# run on the board (Buildroot or Debian)
fw_setenv tx_led 0
```

Or pick another trigger at runtime, as below.

## Taking control from Linux

Everything happens under sysfs. On the board (serial console or SSH):

```sh
# run on the board
ls /sys/class/leds/
cd /sys/class/leds/led0:green
```

*(If the directory name differs, use whatever `ls` shows; it comes from the
`label` property above.)*

**Drive it yourself.** Set the trigger to `none` first, or the kernel keeps
overwriting your value:

```sh
# run on the board, in /sys/class/leds/led0:green
echo none > trigger
echo 1 > brightness        # on
echo 0 > brightness        # off
```

**See what else it can do automatically:**

```sh
# run on the board, in /sys/class/leds/led0:green
cat trigger
```

The current trigger is shown in `[brackets]`. Useful ones include `none`,
`heartbeat`, `timer`, `oneshot`, plus activity triggers such as `mmc0` (SD
card access) and CPU triggers.

**Blink at your own rate**, with no code at all:

```sh
# run on the board, in /sys/class/leds/led0:green
echo timer > trigger
echo 100 > delay_on        # milliseconds lit
echo 900 > delay_off       # milliseconds dark
```

**Flash it on SD-card activity:**

```sh
# run on the board, in /sys/class/leds/led0:green
echo mmc0 > trigger
```

## Using it as a status light in your own program

From a shell script:

```sh
# run on the board: save this as a file, then run it
#!/bin/sh
LED=/sys/class/leds/led0:green
echo none > $LED/trigger
while true; do
    if my_application_is_healthy; then
        echo 1 > $LED/brightness
    else
        echo 0 > $LED/brightness; sleep 0.2; echo 1 > $LED/brightness
    fi
    sleep 1
done
```

From C, it is a file write:

```c
// in your program, running on the board
int fd = open("/sys/class/leds/led0:green/brightness", O_WRONLY);
write(fd, "1", 1);
```

Where a script you write on the board survives depends on the rootfs:

- **`firmware/` (Buildroot)** — the root filesystem is a **ramdisk**, so a
  script vanishes at reboot unless you put it in `/mnt/jffs2` or, better, add it
  to `firmware/patches/` so it becomes part of every build.
- **`firmware-modern/` (Debian)** — `/` is a real ext4 partition, so the file
  stays. Make it run at boot with a systemd unit, the way
  `firmware-modern/debian/overlay/` does; `/mnt/jffs2/autorun.sh` is **not** run
  on this rootfs. Committing it to `firmware-modern/debian/overlay/` still
  matters, or the next card you build will not have it.

## Making your own setting the default at boot

Set the default from userspace, not by editing `linux,default-trigger` in
`zynq-pluto-sdr-fishball.dts`. That applies to both firmware targets, for
different reasons:

- On [`firmware/`](../firmware/README.md) the device tree recompiles
  byte-for-byte identical to the factory board's, which is how this repo shows
  its provenance ([details](provenance.md)). Changing it to set an LED gives
  that up.
- On [`firmware-modern/`](../firmware-modern/README.md) the tree is an overlay
  on ADI's own, so there is no byte-identity to protect, but the tree is the one
  place a setting **cannot** be changed without a reflash. A trigger chosen in
  the tree needs a new `.dtb` on the card; a trigger chosen at boot from
  userspace is one line and can be changed over ssh.
  `firmware-modern/verify_dtb.py` asserts the tree still asks for `heartbeat`,
  and CI runs it.

Which file to change depends on the rootfs:

```sh
# firmware/: add to firmware/src/buildroot/board/pluto/S21misc, inside the start case
echo timer > /sys/class/leds/led0:green/trigger
```

```ini
# firmware-modern/: new file firmware-modern/debian/overlay/etc/systemd/system/my-led.service
[Unit]
Description=Pick a USER LED trigger
After=iiod.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo timer > /sys/class/leds/led0:green/trigger'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
```

On Debian, commit the unit to `firmware-modern/debian/overlay/` and it is in the
next card you build. On Buildroot, capture the `S21misc` edit as a patch so it
survives a clean `setup.sh`, numbered after the highest existing one in
`firmware/patches/` (currently `0021`, so `0022`):

```bash
# run from: firmware/src
diff -u <pristine copy of S21misc> buildroot/board/pluto/S21misc \
    > ../patches/0022-my-led-default.patch
```

Generate it against a *pristine copy* (the file as the existing patches leave
it) rather than with `git diff`: `S21misc` is already touched by patches
`0001`, `0004` and `0012`, so a plain `git diff` would sweep their changes into
yours. Other useful trigger values are `timer`,
`mmc0`, `none` and `default-on`.

## If you want an LED your FPGA logic drives directly

The `USER` LED cannot do this, so you need a pin that reaches the PL
(programmable logic, the FPGA fabric). The easiest are the four 3.3 V header
pins the sample-locked GPIO feature already maps: JP5 pins 7/9/11/13, balls V10/U9/U10/T9, bank 13, `LVCMOS33`
(see [tx-gpio-bitmap.md](tx-gpio-bitmap.md#the-pins)). With that feature off
they are ordinary Linux GPIOs (**978–981** on the factory 5.15 kernel,
**584–587** on 6.12, because the controller's sysfs base moved), so an LED on
one of them
needs **no HDL at all**: wire LED + resistor from the pin to GND (pin 2 or 20) and drive it
from `/sys/class/gpio`. To drive one from your own fabric logic instead, take
the pin over in `system_bd.tcl` the way `tx_gpio_bitmap` does.

Any other header pin needs the **board schematic** first. Do not guess:
driving a pin that turns out to be an input or tied elsewhere can damage the
board. The constraint pattern is the same as every other line in the file:

```tcl
# in firmware/src/hdl/projects/pluto/system_constr.xdc
set_property -dict {PACKAGE_PIN <ball> IOSTANDARD LVCMOS33} [get_ports my_led]
```

Add a matching `output my_led` to `system_top.v`, drive it from your logic,
and rebuild. A counter off `axi_ad9361/l_clk` makes a good first test; see
[Add your own HDL](building.md#add-your-own-hdl).

**The pragmatic middle ground:** if you just want the `USER` LED to reflect
something happening inside the PL, expose that state in an AXI register your
logic already writes, and have a small userspace loop read it and set
`brightness`. The PS does the driving; your HDL decides when.
