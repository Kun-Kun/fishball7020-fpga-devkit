# zc-stream: RX samples over raw TCP, without iiod

A small program on the board that sends a receiver's I/Q samples straight to a
TCP socket, skipping `iiod`'s protocol. It reads the DMA blocks through
libiio's local backend (mapped into the program, so reading copies nothing)
and writes each block to the socket. With 8-bit samples (`-8`) it sustains
**20 MS/s** of one receiver, against 11 MS/s through `iiod`. The patched
SDR++ reads it as its **Fast TCP** transport, and tuning and gain stay in
SDR++. Measurements: [docs/streaming-paths.md](../../../docs/streaming-paths.md).

## As a service, for SDR++

```bash
# run from: the repo root, on your PC
scp -r tools/stream-paths/zc-stream root@192.168.2.1:
```

```bash
# run from: the board (Debian root), in ~/zc-stream
apt install gcc make libiio-dev
make && make install                 # /usr/local/bin/zc-stream and its systemd unit
systemctl enable --now zc-stream     # starts now and at every boot
```

The unit runs `zc-stream -D -8`: **RX1 on port 5555, RX2 on 5556**, int8.
Then in SDR++'s PlutoSDR source set **Transport** to **Fast TCP, 8-bit
(zc-stream)** ([docs/sdrpp.md](../../../docs/sdrpp.md#faster-the-fast-tcp-transport)).
The Debian root has systemd and a compiler; the Buildroot one has neither.

## By hand

```bash
# run from: the board (Debian root), in ~/zc-stream
./zc-stream                     # RX2 on port 5555, int16
./zc-stream -c rx1              # RX1 instead
./zc-stream -D -8               # RX1 on 5555 and RX2 on 5556, int8: what the service runs
./zc-stream --selftest          # checks the -8 pipeline delivers every block in order
```

| option | |
|---|---|
| `-p PORT` | the port, 5555 by default; with `-D`, RX1's port, and RX2 is on the next |
| `-c rx1\|rx2` | the receiver, RX2 by default |
| `-D` | one port per receiver, so a client picks the receiver by port |
| `-8` | int8 samples, the top 8 of the radio's 12 bits, sent by a second thread on the other core |
| `-a CPU` | with `-8`, the core that sends (1 by default, `-1` for either) |
| `-b SAMPLES` | samples per DMA block. By default about 50 ms at the rate set when a client connects (1 M samples at 20 MS/s, 12 288 at the ÷8 decimator's 250 kS/s), so every rate arrives about 20 times a second |
| `-z` | int16 only: `MSG_ZEROCOPY`, kept to show it fails here |

The stream has no header: interleaved I, Q per sample, little-endian int16
(4 bytes per sample) or int8 (2 bytes). Tune, set the rate and the gain
through `iiod` as usual (`iio_attr`, SDR++, pyadi-iio); this carries only the
samples. SDR++'s **Network Source** reads it too (TCP client, the port, Int16 or
Int8, the rate you set), but with no tuning. It scales to the type's full range,
so compared with the PlutoSDR source, levels read about 24 dB lower in Int16
(12 bits of 16) and about 24 dB higher in Int8 (all 8 bits).

**Why 8 bits:** sending is the limit, at about 42 MB/s, and 8-bit samples
halve the bytes. They keep about 48 dB between the strongest and weakest
signal visible at once, instead of 72 dB.

**One program receives at a time.** The board has one receive buffer, which
`zc-stream` holds only while a client is connected. libiio switches that
buffer off before it opens it, so a second program's attempt would stop the
first one's stream even though the attempt itself fails. Two guards stop that:
- `zc-stream` checks `buffer/enable` and refuses a client while another program
  streams, without touching the buffer;
- if a libiio program stops `zc-stream`'s DMA, `zc-stream` rebuilds its buffer
  and carries on after a gap of about a second.

`-z` tries `MSG_ZEROCOPY`, so the network card would read the DMA block
directly. On this kernel the send fails with `EFAULT` (Bad address): the
network stack cannot pin the radio's DMA memory.

Receive only: it never opens a transmit buffer.
