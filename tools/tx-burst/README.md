# tx-burst: play I/Q samples once per trigger

A small program that runs **on the board**: it loads a burst of I/Q samples,
prepares a non-cyclic transmit buffer, and plays the burst once each time a
trigger arrives, a UDP datagram or a rising edge on a GPIO pin. How it fits
with cyclic and streaming transmit, what was measured and the caveats:
[docs/cyclic-buffers.md](../../docs/cyclic-buffers.md#one-shot-bursts-on-a-trigger).

```bash
# run from: the board (Debian root)
apt install gcc make libiio-dev
make
./tx-burst -f burst.iq -u 5556 -a -40        # UDP trigger, TX1 at -40 dB
./tx-burst -f burst.iq -g 75 -a -40          # rising edge on JP5 pin 13
./tx-burst -f burst.iq -u 5556 -m            # muted, with markers on JP5 11/13: a dry run
```

Or build an armhf binary on a PC without touching the board:

```bash
# run from: tools/tx-burst on your PC (podman or docker, with armhf emulation)
podman run --rm --platform linux/arm/v7 -v "$PWD":/src:Z docker.io/library/debian:trixie \
  sh -c 'apt-get update -qq && apt-get install -y -qq gcc make libiio-dev >/dev/null && make -C /src'
```

The burst file is little-endian int16, I then Q per sample for TX1, or I1, Q1,
I2, Q2 with `-2`. Full scale is ±32767. `tx-burst -h` lists every option.

It never raises the output on its own: the attenuation is `-a` (default muted),
set after the buffer starts and read back, and on exit both transmitters are
muted before the buffer is closed. The transmit starve watchdog is off while it
runs, because the DAC starves between bursts by design, and is restored on exit.
