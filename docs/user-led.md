# Controlling the USER LED

How to use the board's one programmable LED: what it shows by default, how to
drive it from Linux or your own program, how to change its boot-time behaviour,
and what to use if you want an LED driven by FPGA logic.

The board has three LEDs between the `USB2.0` and `DEBUG` ports:

| LED | Driven by | Can you control it? |
|---|---|---|
| `PWR` | Power rail | No: hardwired |
| `DONE` | The FPGA's own configuration logic | No: it goes high when the bitstream loads |
| `USER` | Linux, through a PS GPIO pin | **Yes**: this page |

## Drive it from Linux

A *trigger* is a kernel rule that drives an LED automatically. Set it to `none`
first, or the kernel keeps overwriting your value:

```sh
# run from: the board
cd /sys/class/leds/led0:green      # or whatever `ls /sys/class/leds/` shows
echo none > trigger
echo 1 > brightness                # on; 0 for off
cat trigger                        # the available triggers; the current one in [brackets]
echo timer > trigger               # blink at your own rate:
echo 100 > delay_on                #   milliseconds lit
echo 900 > delay_off               #   milliseconds dark
echo mmc0 > trigger                # flash on SD-card activity
```

Others include `heartbeat`, `oneshot` and `default-on`. From a program, write
`1` or `0` to the same `brightness` file.

A script written on the board vanishes at reboot on **Buildroot** (`firmware/`,
a ramdisk) unless it is in `/mnt/jffs2` or, better, in `firmware/patches/`. On
**Debian** (`firmware-modern/`) the root is ext4 and keeps it; run it at boot from
a systemd unit (`/mnt/jffs2/autorun.sh` is **not** run there), and commit it to
`firmware-modern/debian/overlay/` so the next card has it.

## How it is wired

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

Phandle `0x09` is `gpio@e000a000`, the **PS** (processing system, the ARM side)
GPIO controller, so the LED is on **MIO pin 0**.

> **You cannot drive this LED from your HDL.** MIO pins are not routed into the
> Programmable Logic; it does not appear in `system_top.v` or
> `system_constr.xdc`. Driving it is a *software* job.

## What it does by default here: it follows the transmitter

The factory firmware blinks a `heartbeat`. These builds instead select a kernel
trigger called `tx-active` at boot, from
[`S21misc`](../firmware/patches/0012-user-led-follows-the-transmitter.patch) on
Buildroot and `fishball-identity` (run by `fishball-identity.service`) on Debian.
Both check the trigger exists first, so a kernel without patch `0012` keeps the
heartbeat.

> **Lit** whenever either transmit chain is out of full attenuation.
> **Dark** when both sit at the −89.75 dB mute floor.

It is driven from `ad9361_set_tx_atten()`, which every attenuation change passes
through; there is no polling. It follows the attenuator rather than the DMA
buffer because attenuation can be raised with no buffer open, while the LO (local
oscillator) leaks out of the SMA; a stream into a fully attenuated chain leaves
it dark.

| State | LED |
|---|---|
| both channels muted, no buffer | dark |
| TX1, TX2 or both raised, no buffer | **lit** |
| gain set, then a DMA stream running | **lit** |
| DMA stream running, both channels still muted | dark |
| stream ends, kernel re-mutes | dark |

**To keep the heartbeat instead**, set a U-Boot variable and reboot:

```bash
# run from: the board (Buildroot or Debian)
fw_setenv tx_led 0
```

## Making your own setting the default at boot

Choose the trigger from userspace at boot, not by editing
`linux,default-trigger` in `zynq-pluto-sdr-fishball.dts`. On
[`firmware/`](../firmware/README.md) the device tree recompiles byte-for-byte
identical to the factory board's ([provenance](provenance.md)); on
[`firmware-modern/`](../firmware-modern/README.md) a tree change needs a reflash,
and `firmware-modern/verify_dtb.py` (run in CI) asserts the tree still asks for
`heartbeat`.

```sh
# run from: the board at boot - add to firmware/src/buildroot/board/pluto/S21misc, inside the start case
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

On Debian, commit the unit to `firmware-modern/debian/overlay/`. On Buildroot,
capture the `S21misc` edit as a patch numbered after the highest in
`firmware/patches/` (currently `0021`, so `0022`), diffed against a *pristine
copy* (the file as the existing patches leave it), since patches `0001`, `0004`
and `0012` already touch it:

```bash
# run from: firmware/src
diff -u <pristine copy of S21misc> buildroot/board/pluto/S21misc \
    > ../patches/0022-my-led-default.patch
```

## If you want an LED your FPGA logic drives directly

Use a pin that reaches the PL (programmable logic, the FPGA fabric). The easiest
are the four 3.3 V header pins of the sample-locked GPIO feature: JP5 pins
7/9/11/13, balls V10/U9/U10/T9, bank 13, `LVCMOS33`
([tx-gpio-bitmap.md](tx-gpio-bitmap.md#the-pins)). With that feature off they are
ordinary Linux GPIOs (**978–981** on the factory 5.15 kernel, **584–587** on
6.12), so an LED + resistor from a pin to GND (JP5 pin 2 or 20) needs **no HDL**:
drive it from `/sys/class/gpio` ([GPIO](gpio.md)). To drive one from fabric
logic, take the pin over in `system_bd.tcl` the way `tx_gpio_bitmap` does.

Any other header pin needs the **board schematic** first: driving a pin that is
an input or tied elsewhere can damage the board. Then constrain it, add
`output my_led` to `system_top.v`, drive it, and rebuild (a counter off
`axi_ad9361/l_clk` makes a good first test; see
[Add your own HDL](building.md#add-your-own-hdl)):

```tcl
# in firmware/src/hdl/projects/pluto/system_constr.xdc
set_property -dict {PACKAGE_PIN <ball> IOSTANDARD LVCMOS33} [get_ports my_led]
```

To have the `USER` LED reflect PL state, expose it in an AXI register and have
a userspace loop copy it to `brightness`.
