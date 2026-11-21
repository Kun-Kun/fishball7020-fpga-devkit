# Shared RX beat gain

Each RX has an `axis_gain_shift` after its raw/product selector. It receives
80-bit AXIS words containing byte-aligned signed 33-bit I and Q CMPY results.
The selected shift divides each component by 2^(17 − shift), then saturates
to signed 16-bit I/Q for the DMA. Raw RX samples enter at the same Q17 scale.
Shift 0 reproduces the old 16-bit truncation; larger shifts recover lower
product bits before quantization. The AXI stream carries the same number of
samples, with two registers of latency.

The same field drives both RX instances from EMIO bits 30:27, exposed as Linux
GPIO offsets 81–84 (`beat_shift0`–`beat_shift3`). Set all four lines together
between captures.
The board CGI and web beat APIs accept `beat_shift` from 0 to 15; the default
is 0. High shifts can clip the waveform.
