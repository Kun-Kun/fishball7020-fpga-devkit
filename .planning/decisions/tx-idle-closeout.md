---
title: Closing out Goal D — TX idle and unterminated-port protection
date: 2026-09-30
status: locked
scope: firmware-modern/debian/overlay, tools/tx-idle-cases, tools/sample_gpio_clock.py, IDLE-CASES.md, docs/
---

Goal D ended with three contract rows unmet: the transmitter is not provably
silent in every idle condition, the affirmation gate covers only the in-scope
host tools, and two consecutive clean adversarial review rounds were never
achieved. This interview decided what to do about each, plus the bench work
needed to close them. Two facts settled before the questions: the cyclic
backstop `tx_cyclic_timeout_ms` already exists in patch 0015 — measured, and
defaulting to 0, so nothing in the repo ever arms it — and the withdrawn
idle-emission measurement has a written recipe and is re-runnable.

## Locked decisions (interview 2026-09-30)

1. **Arm the cyclic backstop by default.** Every streaming tool in this repo
   transmits cyclically, so a killed cyclic stream is the normal abnormal end
   here, not an exotic one, and "silent after an abnormal stream end" cannot be
   true while the bound is off.
2. **Arm it in `fishball-rf-quiesce`, not the kernel default.** That boot script
   already mutes both attenuators before `iiod` starts and has an `fw_setenv`
   escape hatch, so it is the right home and needs no kernel rebuild — at the
   cost of widening scope beyond the contract's three directories.
3. **Set it to 60 s.** `README.md` and `docs/transmitter-safety.md` already show
   `echo 60000`, so this makes the documentation true rather than aspirational,
   and it is long enough that no legitimate cyclic use notices it.
4. **Give the backstop its own `fw_setenv` switch.** It protects a different
   thing from the boot mute; sharing `tx_quiesce` would mean turning one off
   silently turns the other off too.
5. **Commit the overlay change and patch the live board.** The rootfs is `rw` and
   `fw_setenv` is present, so the running board gets the change now and git
   carries it into the next image, with no reflash and no divergence.
6. **Accept the 60 s bound in `sample_gpio_clock.py`, and print it.** The GPIO
   pins are that tool's purpose and they survive a mute — the nibble never
   reaches the DAC — so the bound costs nothing real, but a raised carrier
   disappearing at 60 s must not look like a fault.
7. **Re-measure idle emission between streams.** It is the one unmet contract row
   that can be closed at the bench now; the row currently says there is no
   measurement at all.
8. **Use the HackRF, not the board's own receiver.** An independent receiver has
   no shared LO and no internal TX-to-RX leak path, which is what makes a null
   mean anything.
9. **HackRF on TX2 through the 30 dB pad, reusing the loop's pad.** Keeps the
   TX1→20 dB→RX1 loop intact for channel 0, and 30 dB is the safer margin for
   the positive control. The TX2→RX2 loop is down for the duration.
10. **Report an upper bound in dBm at the port.** Set by the HackRF's own noise
    floor referred through the pad, with a positive control proving the setup
    sees a transmitter. An idle measurement can only ever be an upper bound, and
    it should say so.
11. **Sample all six termination paths, one 60 s capture each.** The table already
    enumerates them and each leaves the chain in a different state; anything less
    supports a narrower claim than "silent in every idle condition".
12. **Measure path 6 both ways — backstop off, then armed.** The pair is the whole
    evidence for decision 1; either capture alone proves half of it.
13. **Teach the three termination harnesses a channel argument.** They are
    hard-pinned to channel 0 (`set-gain 0`, polling `voltage0`), which does not
    compose with the HackRF being on TX2, and parameterising them makes them
    useful on both ports permanently.
14. **No default channel — refuse without one.** A script that picks a transmit
    port when you forgot to say which is the same class of defect as a gate that
    defaults to affirmed, and one of these ports may have an antenna on it.
15. **Finish the sweep before reporting a loud path.** One path being loud says
    nothing about the other five, and a partial table is how the previous round
    of retractions began.
16. **Bound the boot burst from above after all — supersedes an earlier answer in
    this same interview.** It was first left as a lower bound because it needed
    hands at the bench; decision 9 puts you there anyway, so the reason expired.
17. **Stack the 20 dB and 30 dB pads for 50 dB during the boot capture.** Those
    are the only two on the bench, so no loop stays intact for that capture; the
    test that proves the reading is no longer saturated is that it stops moving
    when attenuation is added.
18. **Run a seventh review round, after the new work rather than before.**
    Otherwise everything decided here lands unreviewed immediately after the
    round meant to certify the tree.
19. **Run an eighth if the seventh is clean.** Two consecutive clean rounds is the
    contract's own bar, and a clean seventh is the only cheap chance to actually
    meet it instead of recording the shortfall a second time.
20. **Record these decisions in `.planning/decisions/`.** Committed with the work,
    so the reasoning travels with it.

## Superseded

- *Leave the boot burst as a lower bound* (answered early in this interview) is
  superseded by decision 16. Recorded rather than dropped, because the premise
  that changed — whether the measurement needed the operator at the bench — is
  the useful part.

## Scope note

Decisions 2 and 5 put work in `firmware-modern/debian/overlay/`, outside the
three directories Goal D scoped itself to (`firmware/patches/`,
`firmware/scripts/`, `tools/`). Taken deliberately, with the alternative — a
kernel default change needing a rebuild and an SD reflash — rejected as heavier
and less reversible.
