# Reaching the board and changing its IP address

Out of the box the board answers on **192.168.2.1** over its USB cable, and asks
your router for an address over the Ethernet socket. This page covers how to
find the board, how to change either address, and where those settings are
stored, which decides what survives a reboot or a reflash.

**Jargon, once:** *DHCP* is a router handing out addresses automatically. A
*static* address is one you fix yourself and the router does not choose. A
*default route* (or *gateway*) is the address a device sends traffic to when the
destination is not on its own network; without one, a device can talk to its
neighbours but not to the internet. *mDNS* lets a device answer to a
`name.local` address without a DNS server. *U-Boot* is the small program that
runs before Linux and loads it.

## The short version

```bash
# run from: the repo root
./devkit net                          # what is it doing now?
./devkit net find                     # locate it without knowing the address
./devkit net dhcp                     # ask the router for an address (the default)
./devkit net static 192.168.1.50      # pin it to one address; an optional second argument is the netmask
./devkit net name mysdr               # change the name it answers to (mysdr.local)
```

`./devkit net dhcp` and `static` write the setting, **read it back before
rebooting**, and then find the board again by name. Switching discards the
address you were connected on, so without that last step you can lose track of
the board.

On the Debian rootfs, `dhcp`, `static` and `name` refuse and print the
equivalent command instead, because Debian does not read the U-Boot variables
they change (see the next section). `find` and the status display work on both.

> ## Which userspace is your board running?
>
> **Most of this page describes the Buildroot rootfs**: the U-Boot variables,
> `S40network` generating `/etc/network/interfaces`, `config.txt` on a USB
> drive, `/mnt/jffs2/autorun.sh`. On the **Debian** rootfs from
> [`firmware-modern/debian`](../firmware-modern/debian/README.md) none of that
> machinery exists, and the routes below behave differently or not at all.
>
> ```bash
> # run on the board
> cat /etc/os-release      # "Debian GNU/Linux 13" -> see the Debian column
> ```
>
> | | Buildroot | Debian |
> |---|---|---|
> | who configures `eth0` | `S40network`, from U-Boot variables | `/etc/network/interfaces`, a fixed file |
> | static address | `fw_setenv ipaddr_eth …` | **edit `/etc/network/interfaces`**; `ipaddr_eth` is read by nothing |
> | hostname / mDNS | `fw_setenv hostname` | `hostnamectl set-hostname`; avahi reads `/etc/hostname` |
> | boot-time extras | `/mnt/jffs2/autorun.sh` | a systemd unit; `autorun.sh` is **never run** |
> | `config.txt` on a USB drive | yes | **no**: there is no mass-storage gadget |
>
> The USB network at **192.168.2.1** works the same on both, and is always the
> way back in. On Debian there is also a serial console on the same cable
> (`/dev/ttyACM0`).

## Reaching the board

In rough order of how well these work:

**1. USB, at 192.168.2.1.** `ipaddr_eth` only touches `eth0`. The USB
interface keeps its own static address whatever you did to Ethernet, so a USB
cable is always the way back in. This is the recovery route.

**2. mDNS: the board announces itself as `fishball.local`.** It runs an avahi
daemon, so no scanning is needed:

```bash
# run from: your HOST
avahi-resolve -n fishball.local
#   fishball.local	192.168.129.142
```

The name follows the `hostname` variable, whose default is `fishball`
(patch `0014`). A board built without `0014` answers to `Fishball7020.local`
(patch `0013` only) or `pluto.local` (neither, the ADALM-Pluto default).
`./devkit net name <host>` changes it on a running board without a rebuild;
setting it to `pluto` restores compatibility with tooling that looks for
`pluto.local`.

mDNS can lag. A board that reboots and takes a *different* DHCP lease may still
be answered for at its old address for a while. `./devkit net find` handles
that; by hand, look for the board's MAC in `ip neigh`.

**3. libiio finds it by itself.** The board advertises the IIO service over
DNS-SD (service discovery on top of mDNS), and `iio_info -s` finds it without
an address:

```bash
# run from: your HOST
iio_info -s
#   1: 192.168.129.200 (FISH Ball PlutoSDR Rev.A (Z7020-AD9361)),
#      serial=b8f4c99de8525565d3f4fe3c917ad834 [ip:fishball.local]
```

This gives the address, the model, the serial, and confirms the radio service
is up. `ip:fishball.local` then works as a libiio URI, so no address needs to
be hard-coded.

```bash
# run from: your HOST
avahi-browse -tpr _iio._tcp
#   =;...;iiod on pluto;_iio._tcp;local;fishball.local;192.168.129.200;30431;
```

**4. The serial console.** The FT2232H gives you a console at 115200 baud on
one of its two ports, independent of any network setting. Use it when a static
address collides with something and the board is unreachable on both USB and
Ethernet.

**5. Your router's DHCP lease table.** The board's MAC is in the `ethaddr`
variable and begins with Xilinx's `00:0a:35` prefix, which makes it easy to
spot in a list of leases.

**6. `/opt/ipaddr-<interface>`, for USB only.** The mdev hotplug hook
`ifupdown.sh` writes the address of each interface it brings up, and
`update.sh` copies those files onto the USB drive, so the board's address can
be read off a flash drive. The file only appears for interfaces brought up *by
hotplug*: on a board whose `eth0` is configured at boot by `ifup -a`,
`/opt/ipaddr-usb0` exists and `/opt/ipaddr-eth0` does not. Do not rely on it
for Ethernet.

## Four ways to change the address

All four write, in the end, to the same place: the U-Boot environment in QSPI
flash ([explained below](#where-the-address-lives)). Everything in this
section applies to Buildroot; on Debian, edit `/etc/network/interfaces`.

### Route 1: over ssh, with `fw_setenv`

The direct way. `./devkit net` is a wrapper around this.

**A fixed address on your router's network:**

```bash
# run on the board
fw_setenv ipaddr_eth 192.168.1.50
fw_setenv netmask_eth 255.255.255.0
reboot
```

**Back to DHCP.** `fw_setenv` with no value deletes the variable:

```bash
# run on the board
fw_setenv ipaddr_eth
fw_setenv netmask_eth
reboot
```

**Check before you reboot.** `fw_setenv` writes to flash immediately, and a
typo here loses you the board's Ethernet address:

```bash
# run on the board
fw_printenv ipaddr_eth netmask_eth
```

The whole thing in one line from your PC:

```bash
# run from: your HOST, anywhere
ssh root@192.168.2.1 'fw_setenv ipaddr_eth 192.168.1.50 && fw_printenv ipaddr_eth'
# password: analog
```

A reboot is needed because `S40network` only regenerates the config at startup.
`/etc/init.d/S40network restart` re-reads the environment and reconfigures
every interface without a reboot, which drops your ssh session if you are
connected over the interface you changed.

### Route 2: `config.txt` on the board's USB drive

When the board's USB port is plugged into a PC it also appears as a small USB
flash drive containing **`config.txt`**. This route needs no ssh and no
terminal. Buildroot only.

1. Plug the board's USB port into your PC. A drive called `PlutoSDR` appears.
2. Open `config.txt` in any text editor.
3. Edit the values you want, set `reset = 1` under `[ACTIONS]`, save.
4. **Eject the drive.** Nothing happens until you eject; that is what the board
   watches for.

The file looks like this; the section to edit for a router connection is
`[USB_ETHERNET]`:

```ini
# config.txt on the PlutoSDR USB drive (excerpt)
[NETWORK]
hostname = pluto
ipaddr = 192.168.2.1
ipaddr_host = 192.168.2.10
netmask = 255.255.255.0

[USB_ETHERNET]
ipaddr_eth =
netmask_eth = 255.255.255.0

[ACTIONS]
reset = 1
```

> **The section name is wrong for this board.** `ipaddr_eth` and `netmask_eth`
> sit under `[USB_ETHERNET]`, but on the Fishball7020 they configure the **RJ45
> gigabit socket**, driven by the RTL8211F PHY. The name is inherited from the
> ADALM-Pluto, which has no Ethernet PHY and could only get an `eth0` from a USB
> Ethernet dongle. Same variable, same `eth0`, different hardware behind it.

Leaving `ipaddr_eth` blank selects DHCP, as with `fw_setenv`. Patch `0013`
changes how `S40network` *writes* the interface file; it does not touch
`update.sh` or the variables `config.txt` feeds it, so this route still sets a
static address and the stable MAC.

Under the hood, `/sbin/update.sh` compares the file's md5 against a stored copy,
parses the `[NETWORK]`, `[WLAN]`, `[SYSTEM]` and `[USB_ETHERNET]` sections, and
writes every value in one batch:

```sh
# in /sbin/update.sh on the board (excerpt)
echo "ipaddr_eth $ipaddr_eth"   >> /opt/fw_set.tmp
echo "netmask_eth $netmask_eth" >> /opt/fw_set.tmp
fw_setenv -s /opt/fw_set.tmp
```

It reboots if `reset = 1`, and drops a file called `SUCCESS_ENV_UPDATE` on the
drive if the write worked, or `FAILED_INVALID_UBOOT_ENV` if it did not. Check
for those before assuming it took.

### Route 3: the U-Boot console

From the serial console at 115200 baud, interrupt the 3-second boot delay:

```
# at the U-Boot prompt, serial console, 115200 baud
setenv ipaddr_eth 192.168.1.50
saveenv
boot
```

`saveenv` writes the same QSPI environment `fw_setenv` does. Use it when Linux
is not reachable at all.

### Route 4: temporary, no reboot, nothing written

For trying an address before committing to it. None of this survives a reboot:

```bash
# run on the board
ip addr add 192.168.1.50/24 dev eth0     # add a second address, keep the old one
ip route add default via 192.168.1.1     # give it a gateway too
```

To undo it, `ip addr del 192.168.1.50/24 dev eth0`, or reboot.

## Where the address lives

**The board's addresses are not stored in any file on the SD card.** On
Buildroot they live in the **U-Boot environment**, a 128 KB block in the
board's on-board QSPI flash chip, a separate memory from the SD card.

```bash
# run on the board
cat /etc/fw_env.config
#   /dev/mtd1    0x0000    0x20000    0x20000
cat /proc/mtd | grep mtd1
#   mtd1: 00020000 00010000 "qspi-uboot-env"
```

At every boot, `/etc/init.d/S40network` reads that environment with
`fw_printenv` and **generates** `/etc/network/interfaces`, `/etc/udhcpd.conf`
and `/opt/config.txt` from it. Two consequences:

- **Editing `/etc/network/interfaces` does not survive a reboot.** It is a
  generated file. Editing it is fine for a test and useless for a lasting
  change.
- **The defaults are compiled into the script, not stored anywhere.**
  `fw_printenv ipaddr` reporting `"ipaddr" not defined` does not mean the board
  has no USB address; the script falls back to `192.168.2.1`.

Because the environment is in QSPI flash, **address settings survive
reflashing the SD card**, including `./devkit flash --all`.

### The variables

All of these are read by `S40network`. Only the first two concern the Ethernet
socket you plug into a router.

| Variable | Default if unset | What it sets |
|---|---|---|
| `ipaddr_eth` | *(unset)* | **The Ethernet socket. Set it for a static address; leave it unset for DHCP.** |
| `netmask_eth` | `255.255.255.0` | The Ethernet netmask, used only when `ipaddr_eth` is set |
| `ipaddr` | `192.168.2.1` | The board's own address on the USB cable (`usb0`) |
| `ipaddr_host` | `192.168.2.10` | The single address the board's DHCP server hands *your PC* over USB |
| `netmask` | `255.255.255.0` | The USB netmask |
| `hostname` | the contents of `/etc/hostname`: `fishball` | The hostname, and therefore the mDNS name `fishball.local` |
| `usb_ethernet_mode` | `rndis` | USB Ethernet flavour: `rndis`, `ncm` or `ecm` |
| `ethaddr` | *(stored in the environment)* | The Ethernet MAC; Linux uses it for `eth0` with patch `0013` |
| `ssid_wlan`, `pwd_wlan`, `ipaddr_wlan` | *(unset)* | A USB Wi-Fi dongle, if you fit one |

**`ipaddr_eth` is a switch, not just an address.** `S40network` branches on
whether it has a value:

```sh
# in /etc/init.d/S40network on the board (trimmed)
if [ -n "$ETH_IPADDR" ]; then
        echo "iface eth0 inet static"          >> $IFAC
        echo "\taddress $ETH_IPADDR"            >> $IFAC
        echo "\tnetmask $ETH_NETMASK"           >> $IFAC
else
        echo "iface eth0 inet dhcp"             >> $IFAC
fi
```

So "go back to DHCP" is not a separate setting: it is *deleting* `ipaddr_eth`.

### Why editing `uEnv.txt` does not work

`uEnv.txt` on the SD card looks like the obvious file to edit. It is plain text
and contains the lines you want to change:

```bash
# run from: your HOST, in firmware/
grep -E '^(ipaddr|netmask|hostname)' output/uEnv.txt
#   ipaddr=192.168.2.1
#   ipaddr_host=192.168.2.10
#   netmask=255.255.255.0
```

**Editing those does nothing to the running Linux system.** U-Boot reads
`uEnv.txt` into the environment it holds *in RAM*:

```sh
# in uEnv.txt
importbootenv=echo Importing environment from SD ...; env import -t ${loadbootenv_addr} $filesize
```

`env import` never writes flash, and there is no `saveenv` anywhere in the SD
boot path. The values exist while U-Boot runs and are gone by the time Linux
starts. Linux's `fw_printenv` reads `/dev/mtd1`, which `env import` did not
touch. They are not used inside U-Boot either: this U-Boot is built with
**`# CONFIG_NET is not set`**, so it has no network stack, no `tftp` and no
`ping`. `ipaddr`, `netmask` and `ethaddr` matter only because **Linux** reads
them out of QSPI.

The two disagree on a running board:

```bash
# run from: your HOST
grep '^ipaddr=' firmware/output/uEnv.txt      # ipaddr=192.168.2.1
ssh root@192.168.2.1 'fw_printenv ipaddr'     # ## Error: "ipaddr" not defined
```

The board is on `192.168.2.1` anyway, because that is also `S40network`'s
built-in default. An edit to `uEnv.txt` that "worked" worked for that reason.
To make an address stick, use Route 1 or Route 3.

## A static address has no gateway and no DNS

On Buildroot, **a static Ethernet address gets no default route and no DNS
server.** The static branch of `S40network` above writes `address` and
`netmask`, with no `gateway` line, and nothing writes `/etc/resolv.conf`. On a
board with `ipaddr_eth=192.168.129.200`:

```bash
# run on the board
ip route
#   192.168.2.0/24     dev usb0 scope link  src 192.168.2.1
#   192.168.128.0/23   dev eth0 scope link  src 192.168.129.200
cat /etc/resolv.conf     # No such file or directory
ping -c1 8.8.8.8         # fails: no route
```

Two link-scope routes and no `default via`: the board reaches its own subnet
and nothing else. For SDR work that usually does not matter, since libiio talks
to it directly and your PC is on the same subnet, but `ntpd`, `git`, `wget` and
anything that resolves a name fail without an obvious reason.

**DHCP does not have this problem.** udhcpc's script sets both:

```sh
# in /usr/share/udhcpc/default.script on the board (excerpt)
route add default gw $i dev $interface
...
echo "nameserver $i" >> "$RESOLV_CONF"
```

> **A DHCP reservation is usually the right answer.** Leave `ipaddr_eth` unset,
> and tell your router to always give this board the same address. You get a
> predictable address, a working gateway, working DNS, and nothing to undo on
> the board if you move it to another network.

For a static address *with* internet access, add what static mode omits to
`/mnt/jffs2/autorun.sh`:

```bash
# run on the board
cat >> /mnt/jffs2/autorun.sh <<'EOF'
ip route add default via 192.168.1.1
echo "nameserver 192.168.1.1" > /etc/resolv.conf
EOF
```

On Buildroot `/mnt/jffs2` is the board's only writable, persistent partition,
and `autorun.sh` runs at every boot, after the network is up. It survives
reflashing the kernel, device tree and bitstream, and it is the first place to
look when the board behaves in a way the firmware source cannot explain; see
[troubleshooting](troubleshooting.md).

> **On Debian `autorun.sh` is never run.** Nothing under `/etc/systemd`,
> `/etc/init.d` or `rc.local` references it. The root is ext4 and writable, so
> put a persistent change in a drop-in file or a systemd unit next to
> `fishball-identity.service`. An `autorun.sh` that worked on Buildroot stops
> running when the board moves to Debian, and one left over from Buildroot
> looks live but is not.

## The router shows a MAC address instead of a name

The name a router displays comes from **DHCP option 12**, which is separate
from the mDNS name. The stock firmware runs udhcpc with no hostname option, so
the router has nothing to list but the MAC.

On stock firmware that MAC is not stable either. The device tree carries no
`local-mac-address`, so the driver picks a random one at every boot:

```
# kernel log on stock firmware
macb e000b000.ethernet: invalid hw address, using random
```

A new MAC every boot means the router sees a **new device** each time and hands
out a new lease (for example `.139`, then `.140`), and a DHCP
reservation is impossible.

`firmware/patches/0013` fixes both by adding two lines to the interface stanza
`S40network` generates:

```
# /etc/network/interfaces as generated with patch 0013
iface eth0 inet dhcp
	hostname fishball
	hwaddress ether 00:0a:35:00:01:22
```

busybox ifupdown turns `hostname` into `udhcpc -x hostname:` and `hwaddress`
into an `ip link set addr` before the interface comes up. The MAC is the
`ethaddr` variable from the U-Boot environment (`fw_printenv ethaddr`); if
`ethaddr` is unset the line is omitted. The Debian
rootfs does the same in its fixed `/etc/network/interfaces`.

A static stanza gets the `hwaddress` line too, but not `hostname`: a static
address has no DHCP conversation, so the router lists a pinned board by MAC.
mDNS still answers, so `fishball.local` works either way.

> **If you run two of these boards on one network**, check they do not share an
> `ethaddr`. It lives in each board's QSPI environment, and nothing here can
> tell you whether the factory wrote the same value to every unit.
> `fw_setenv ethaddr <mac>` gives one of them a different address.

## What DHCP exposes, and what it does not

A static address on Buildroot has no default route, so the board cannot reach
the internet. DHCP supplies a gateway, so the board goes from no internet
access to full outbound access. On a board in DHCP mode:

- **Outbound: everything.** ICMP, DNS and HTTP to the internet all succeed. No
  service on the board uses it (there is no `ntpd`, no `cron`, and nothing that
  phones home), but the path is open.
- **Inbound from the internet: no route in**, as long as your router does
  ordinary NAT. Every address the board holds is private (RFC1918), and **the
  kernel has no IPv6 stack at all**, which closes the usual accidental-exposure
  path (a globally routable v6 address behind a router with no v6 firewall).
- **Inbound from your LAN: wide open.**

| Port | Service | Authentication |
|---|---|---|
| 22/tcp | dropbear, root shell | password `analog`, the documented default |
| 30431/tcp | `iiod` | **none** |
| 80/tcp | httpd, the info page | none; discloses serial, MACs, kernel and firmware versions |
| 5353/udp | avahi (mDNS) | n/a |
| 67/udp | udhcpd | limited to `usb0` by its config, so it does not serve your LAN |

There is **no packet filter on the board**: no netfilter tables are
registered.

`iiod` has no authentication and no way to add any, so anyone who can reach
port 30431 can tune, receive **and transmit**. On a board with a power
amplifier that is an RF-emissions question, not only a data one. Network
isolation is the only control: a segregated VLAN, or the router's firewall.

To keep the board off the internet, a static address does it: no gateway is
written, so it talks to its own subnet and nothing else.

**Changing the root password does not survive a reboot on its own** on
Buildroot. `/etc` is in the ramdisk. `S21misc` restores
`/mnt/jffs2/etc/{passwd,shadow,group}` at boot, but only when `password.md5`
alongside them verifies, so persisting a new password means copying those
files there and writing that checksum.

## Logging in without a password

```bash
# run from: the repo root
./devkit ssh-key
ssh fishball
```

It is idempotent, so running it again is harmless, and
`./devkit ssh-key --check` reports whether it is already done.

**What it sets up**

| | |
|---|---|
| `~/.ssh/fishball` | an ed25519 key used for **nothing else** |
| the board's `/root/.ssh/authorized_keys` | the public half, mode 600, root-owned |
| `~/.ssh/config` | a `Host fishball` block, appended without touching what is already there |

**Why a dedicated key.** This board ships with a published root password and
sits on whatever network you put it on. Giving it your everyday key means a
board on a conference wifi holds a credential that opens your other machines.
A key used for one board can be deleted without consequence.

**How you know it worked.** The last step logs in with `BatchMode=yes`, which
cannot fall back to a password. A pass means the key did the work.

**The password stays enabled.** On the Debian rootfs, turning it off is one
line:

```bash
# run on the board - Debian only, and ONLY after key login is proven
echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/no-password.conf
systemctl restart ssh
```

A typo in that line locks you out, and recovery means taking the card out: the
Debian board has no working `systemctl reboot` (logind is masked; see
`firmware-modern/debian/overlay/etc/systemd/system/systemd-logind.service.d/`)
and no console at all without the FTDI `DEBUG` cable. Prove key login first,
and keep the password until you have.

If `ssh fishball` stops resolving, see [Reaching the board](#reaching-the-board):
mDNS can answer with an old address after the board takes a new lease.

## If you have locked yourself out

In order of effort (Buildroot):

1. **USB cable, `ssh root@192.168.2.1`.** Undo it with `fw_setenv`. This works
   unless you changed `ipaddr` as well.
2. **`config.txt` on the USB drive** (Route 2). Needs no shell and no network:
   set the values, `reset = 1`, eject.
3. **Serial console**, 115200 baud. Log in, `fw_setenv`, reboot.
4. **U-Boot console** (Route 3), same serial port, interrupt the 3-second boot
   delay. `setenv ipaddr_eth`, `saveenv`, `boot`.

Reflashing the SD card does *not* help: the addresses are in QSPI flash, and a
fresh SD card does not touch them.

### One way the whole environment can reset itself

U-Boot's Zynq board code has a "button" that resets the environment to its
compiled-in defaults, and it is **compiled in on this board**
(`CONFIG_MISC_INIT_R` is defined in `include/configs/zynq-common.h`):

```c
/* in U-Boot's board/xilinx/zynq/board.c (excerpt) */
#define BUTTON_GPIO 10
    gpio_direction_input(BUTTON_GPIO);
    if (!gpio_get_value(BUTTON_GPIO))
        set_default_env("Button pressed: Using default environment\n");
```

If **MIO 10 reads low at boot**, every variable saved with `fw_setenv` is gone
(`ethaddr`, `hostname`, `ipaddr_eth`, `tx_quiesce`, all of them), and the only
notice is one line on the serial console.

On this board MIO 10 is an input reading **1** (high), so the branch is not
taken, but nothing in the firmware guarantees that. The symptom to recognise: a
board that has forgotten its settings and gone back to a random MAC every boot,
which looks like a hardware fault or corrupted flash rather than a pin.

For anyone replacing U-Boot: patch `0001` changed the *board-revision* GPIO
from 10 to 14 in the environment string and left `board.c`'s `BUTTON_GPIO` at
10. Nothing records whether that is intentional.

## Where the settings live, in one picture

```
# Buildroot: where each network setting is stored and who reads it
QSPI flash /dev/mtd1 "qspi-uboot-env"        <- the only persistent store
   |  fw_setenv (ssh)          Route 1
   |  update.sh <- config.txt  Route 2   (USB drive, no shell needed)
   |  saveenv (U-Boot console) Route 3
   v
S40network reads it with fw_printenv, at every boot
   |
   +-> /etc/network/interfaces   generated, do not edit
   +-> /etc/udhcpd.conf          generated (the USB-side DHCP server)
   +-> /opt/config.txt           generated (what you see on the USB drive)

SD card uEnv.txt  -> U-Boot's RAM environment only -> discarded before Linux
/mnt/jffs2/autorun.sh -> runs after all of the above; the place for a gateway
```

## Related

- [Flashing the board](flashing.md): which does *not* change these settings
- [Troubleshooting](troubleshooting.md): `/mnt/jffs2` and other invisible state
- [Capturing IQ](capturing-iq.md): using `ip:fishball.local` instead of an address
