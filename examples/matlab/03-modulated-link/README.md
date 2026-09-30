# 03 — a modulated link you can measure

QPSK or QAM symbols go out of the transmitter, round a cable and back into the
receiver, and the example measures how cleanly they arrive (EVM). Change the
gain, the order or the channel and watch the number.

> **This one transmits.** `PadDb` is **required** and has no default. This
> board reaches about **+19 dBm**; its own receive port is rated **+2.5 dBm**.
> A cable from TX to RX with no attenuator in it destroys the receiver. Fit
> **at least 20 dB** and tell the example how much with `PadDb`.
>
> No attenuator? Use `'Source', 'loopback'`, which routes the transmit samples
> into the receive path *inside the AD9361*. Nothing reaches a mixer, the
> amplifier or a port.

**What you need:** TX1 cabled to RX1 through a 20 dB attenuator (or no cable at
all with `'Source', 'loopback'`), Communications Toolbox and the ADALM-Pluto
support package.

```bash
# run from: the repo root, in a SHELL
./devkit matlab shell
```

```matlab
>> % run from: the MATLAB prompt (./devkit matlab shell puts the example on the path)
>> modulated_link('PadDb', 20)                      % TX1 -> pad -> RX1
>> modulated_link('PadDb', 20, 'Order', 16)         % 16-QAM
>> modulated_link('PadDb', 20, 'RxGain', 30)        % see the note on gain
>> modulated_link('PadDb', 20, 'TxChannel', 2, 'RxChannel', 2)
>> modulated_link('Source', 'loopback')             % no cable, no RF at all
```

Defaults: 900 MHz, 3 MS/s at 4 samples per symbol (750 ksym/s), QPSK, TX gain
−30 dB, RX gain 20 dB.

## What it measures

**EVM** (error vector magnitude): how far each recovered symbol lands from
where it should, as a percentage. Every impairment eventually shows up in it,
which makes it the number to watch while you change something.

TX1 → 20 dB → RX1 at 900 MHz, 750 ksym/s:

| | EVM | peak of 2047 |
|---|---|---|
| QPSK, RxGain 20 | 4.53 % | 290 |
| QPSK, RxGain 30 | **4.44 %** | 913 |
| QPSK, RxGain 40 | 4.67 % | 2048 — clipping |
| QPSK, RxGain 50 | 12.34 % | 2048 — clipping badly |
| 16-QAM, RxGain 40 | 6.25 % | clipping |

Two things to take from that table:

- **More gain is not better.** The best reading is in the middle. Past full
  scale (2047 counts) the measurement collapses, because a clipped
  constellation measures your ADC rather than your link.
- **EVM barely improves between gain 20 and 30** (4.53 → 4.44 %), so the limit
  here is not thermal noise. Through only 20 dB of pad, the board's own TX→RX
  leakage and the transmitter's own noise are in the same picture.

## The chain

```
random symbols -> RRC shaping -> cyclic transmit
capture -> matched filter -> symbol timing -> carrier recovery -> EVM
```

RRC is a root raised cosine pulse-shaping filter; the receiver applies the same
filter again (the matched filter). Timing and carrier recovery are
Communications Toolbox System objects rather than hand-written loops, because
that is what you would use in practice and the subject here is the measurement.
Only the **last 40 %** of symbols are measured: the loops take time to settle,
and measuring through that transient reports an EVM worse than the hardware.

## Channels

`TxChannel` and `RxChannel` each take 1 or 2. Channel 2 does not go through the
support package, because `sdrtx` and `sdrrx` **both** insist
`ChannelMapping must be equal to 1`. TX2 is driven with `iio_writedev -c` and
RX2 read with `iio_readdev`, wrapped so `release()` works the same either way.

If you select TX2, check what is on that port first. An **unterminated** output
is not a safe place to put power: reflection tolerance is unspecified for both
the AD9361 and the PGA-102+ amplifier.

## What `safeTransmit` will refuse

Every transmit goes through `fishball.safeTransmit`, which works out the level
at the receive port from `+19 dBm + Gain − PadDb` and refuses anything within
10 dB (`Headroom`) of the +2.5 dBm rating:

```
Refusing: about -6.0 dBm would reach the receive port.

  +19 dBm flat out -5.0 dB gain -20.0 dB pad = -6.0 dBm, against a +2.5 dBm rating
  (10 dB of headroom asked for).

  Lower Gain to -6.5 dB or less, or fit 2 dB more pad.
```

It also reads the attenuation back **off the chip** after the buffer starts and
stops the transmitter if it disagrees by more than 0.5 dB. Patch `0005`
restores a cached attenuation when a buffer opens, so a value written
beforehand can be silently replaced: a value you wrote is an intention, a value
you read back is a fact.
