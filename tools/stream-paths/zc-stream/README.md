# zc-stream: RX samples over raw TCP, without iiod

An experiment from [docs/streaming-paths.md](../../../docs/streaming-paths.md):
a small program on the board that sends one receiver's I/Q samples straight to
a TCP socket, skipping `iiod`'s protocol. It reads the DMA blocks through
libiio's local backend (mapped into the program, so reading copies nothing)
and writes each block to the socket: one CPU copy per sample instead of two.

It sustains a few MS/s more than `iiod`, not the 20 MS/s a wide SDR++ view
would need; the page has the numbers and the reasons.

```bash
# run from: the board (Debian root)
apt install gcc make libiio-dev
make
./zc-stream                 # RX2 on TCP port 5555, 1 M-sample blocks
./zc-stream -c rx1 -p 5556  # RX1 on another port
```

The stream is little-endian int16 I, Q per sample, 4 bytes, no header. Tune,
set the rate and the gain through `iiod` as usual (`iio_attr`, SDR++,
pyadi-iio); this carries only the samples. In SDR++, read it with the
**Network Source**: TCP (Client), the board's address, port 5555, Int16, and
the sample rate you set. Levels read about 24 dB low there, because SDR++
scales int16 to ±32768 and the radio's 12-bit samples reach ±2048.

`-z` tries `MSG_ZEROCOPY`, so the network card would read the DMA block
directly. On this kernel the send fails with `EFAULT` (Bad address): the
network stack cannot pin the radio's DMA memory. It is kept to show that.

One client at a time; the RX buffer exists only while a client is connected.
Receive only: it never opens a transmit buffer.
