# 03 — a modulated link you can measure

```bash
# run from: the repo root, in a SHELL
./devkit matlab shell
```

```matlab
>> modulated_link('PadDb', 20)                      % TX1 -> pad -> RX1
>> modulated_link('PadDb', 20, 'Order', 16)         % 16-QAM
>> modulated_link('PadDb', 20, 'RxGain', 30)        % see the note on gain
>> modulated_link('PadDb', 20, 'TxChannel', 2, 'RxChannel', 2)
>> modulated_link('Source', 'loopback')             % no cable, no RF at all
```

> ## ⚠️ This one transmits
>
> `PadDb` is **required** and has no default. This board reaches about
> **+19 dBm**; its own receive port is rated **+2.5 dBm**. A cable from TX to RX
> with no attenuator in it destroys the receiver. Fit **at least 20 dB**.
>
> No attenuator? Use `'Source', 'loopback'`, which routes transmit samples into
> the receive path *inside the AD9361*. Nothing reaches a mixer, the amplifier
> or a port.

## What it measures

**EVM** — how far each recovered symbol lands from where it should, as a
percentage. It is the number every impairment eventually shows up in, and the
one worth watching while you change something.

Measured on the board this was written against, TX1 → 20 dB → RX1 at 900 MHz,
750 ksym/s:

| | EVM | peak of 2047 |
|---|---|---|
| QPSK, RxGain 20 | 4.53 % | 290 |
| QPSK, RxGain 30 | **4.44 %** | 913 |
| QPSK, RxGain 40 | 4.67 % | 2048 — clipping |
| QPSK, RxGain 50 | 12.34 % | 2048 — clipping badly |
| 16-QAM, RxGain 40 | 6.25 % | clipping |

Two things to take from that table. **More gain is not better** — the best
reading is in the middle, and past full scale the measurement collapses because
a clipped constellation measures your ADC rather than your link. And **EVM
barely improved between gain 20 and 30** (4.53 → 4.44 %), which says the limit
here is not thermal noise; through only 20 dB of pad the board's own TX→RX
leakage and the transmitter's own noise are in the same picture.

## The chain

```
random symbols -> RRC shaping -> cyclic transmit
capture -> matched filter -> symbol timing -> carrier recovery -> EVM
```

Timing and carrier recovery are Communications Toolbox System objects rather
than hand-rolled, because that is what you would really use and because the
point here is the measurement, not the loops. The **last 40 %** of symbols are
measured, not all of them — loops take time to settle, and measuring through
the transient is the most common way to publish an EVM worse than the hardware.

## Channels

`TxChannel` and `RxChannel` each take 1 or 2, and neither goes through the
support package for channel 2 — `sdrtx` and `sdrrx` **both** insist
`ChannelMapping must be equal to 1`. TX2 is driven with `iio_writedev -c` and
RX2 read with `iio_readdev`, wrapped so `release()` works the same either way.

If you select TX2, check what is on that port first. An **unterminated** output
is not a safe place to put power: reflection tolerance is unspecified for both
the AD9361 and the PGA-102+.

## What `safeTransmit` will refuse

```
Refusing: about -6.0 dBm would reach the receive port.

  +19 dBm flat out -5.0 dB gain -20.0 dB pad = -6.0 dBm, against a +2.5 dBm rating
  (10 dB of headroom asked for).

  Lower Gain to -6.5 dB or less, or fit 2 dB more pad.
```

It also reads the attenuation back **off the chip** after the buffer starts and
stops the transmitter if it disagrees by more than 0.5 dB. Patch `0005` restores
a cached attenuation when a buffer opens, so a value written beforehand can be
silently replaced — a value you wrote is an intention, a value you read back is
a fact.
