# Improvement goals

Four execution contracts for the next round of work on this devkit, in the
order they should be run.

A *goal contract* is a prompt written so that "done" is checkable by someone
other than the agent that did the work. Instead of "improve the build", it
names one end state, the exact output that proves it, what must not change,
when to stop, and what to print at the end. The point is to make a false
"finished" hard to produce. These were compiled with the `goal-creator` skill
in `.claude/skills/goal-creator/`.

## How to run them

One goal per session, in a fresh context — a clean context is part of what
makes the contract testable. Paste the contract body as the opening prompt.

The `/goal` prefix is Codex's native primitive; in Claude Code just paste the
body without it.

Do **not** run these concurrently against this repo. They collide three ways:
D, A and C all drive the board at `192.168.2.1`, their file scopes overlap
(`tools/`, `docs/`), and concurrent edits to the build scripts destroy Goal C's
before/after measurement while still producing plausible-looking numbers.

Once A is finished, B *can* run in a `git worktree` alongside C if you are
time-pressed — they touch disjoint files, and B needs the board only for a
single getting-started check. Sequential is simpler and keeps failure
attribution clean.

## Sequence

| Order | Goal | Why here |
|-------|------|----------|
| 1 | **D — TX idle and unterminated-port protection** | Protects the hardware steps in all three others. Verified through the 20 dB loop with transmit gain capped at −10 dB — see "Before you start". |
| 2 | **A — User-friendliness** | Discovers the undocumented steps. Its flash is plain devkit firmware, which matches where the board is already headed. |
| 3 | **B — README and Claude skill** | Documents a flow that is already clean, instead of enshrining friction in prose. |
| 4 | **C — Efficiency** | Longest runtime, highest risk, takes the board into custom HDL. By then tooling, docs and TX safety are all stable. |

## Constraints shared by all four

- Flash only via the SD partition. Never DFU.
- Never transmit with a TX port unterminated — confirm an antenna or 50 ohm
  load is attached before any TX-enabling step. Reflected power damages the PA.
- Never bypass, weaken or stub the TX safety ramp check.
- **TX2 now has an antenna on it, so it radiates.** This inverts the old
  constraint: TX2 is no longer an unterminated port to protect, it is a live
  one. Transmitting on it puts power in the air, which is a licensing question
  and the operator's call — so do not key TX2 as part of any of these goals.
  Use TX1, which goes into a cable and a pad.

## Before you start

> **Status as of 2026-09-29.** The paragraph that used to be here described a TX
> fault from 2026-09-20 that has since been resolved. What follows was measured
> on the board this week, over USB, rather than assumed.

**The TX path works.** The fault first seen at 18:30 on 2026-09-20 is gone. With
TX1 looped to RX1 through a 20 dB pad, a tone landed at +299 812.5 Hz against a
commanded +299 812.5 — 0.0 Hz error — with RX1 reading 33.5 dB above the antenna
on RX2, a monotonic gain sweep from −45 dB to −10 dB, and 70.4 dB of mute depth
once the transmitter was released. Both transmitters read −89.75 dB and all
eight DDS scales read 0.000000 afterwards. So Goal D's stop condition about that
fault now evaluates false, and Goal C has nothing pending to fight.

**Three things to settle before pasting any of these:**

1. **Goal D now runs on the 20 dB loop, with transmit gain capped at −10 dB.**
   It originally demanded 50 dB, which this bench does not have. That was
   changed deliberately, in the contract body, with the arithmetic written down
   — not substituted quietly by an agent mid-run.

   The arithmetic, using the board's own capped estimate of **+19 dBm** flat out
   and the receive port's **+2.5 dBm** rating:

   | | at the receive port | margin to the rating |
   |---|---|---|
   | full output through 20 dB | **−1 dBm** | 3.5 dB |
   | **capped at −10 dB gain**, through 20 dB | **−11 dBm** | **13.5 dB** |

   So 20 dB alone already protects the receiver even at full output. The cap
   exists to keep the devkit's own convention: `fishball.TxSink` refuses
   anything that would land above `2.5 − 10 = −7.5 dBm`, which at 20 dB means a
   transmit gain no hotter than about −6.5 dB. −10 dB sits comfortably inside
   that and needs no override.

   This costs Goal D nothing it needs. Its job is proving the transmitter is
   **silent** when idle, and a smaller pad makes leakage *easier* to see, not
   harder — 50 dB would have buried the very thing being measured. Only the
   deliberate transmissions are attenuated, and they do not need full power.

   If you do acquire more attenuation, chaining a second 20 dB pad (40 dB total)
   is strictly better and needs no further edit — the contract says "at least
   20 dB".

2. **Goal A points at vendor documentation that is no longer on this machine.**
   It names `/home/matthieu/Downloads/New version_7020_AD936X_SDR资料/…`, which
   does not exist — neither under that home directory (the account is now
   `matsvandamme`) nor under the current one, and nothing else in the repo
   references it. Either restore those files and correct the path, or strike
   that clause before pasting, or Goal A opens by hunting for something absent.

3. **The board is not connected right now.** No USB gadget is enumerated and
   192.168.2.1 does not answer. D, A and C all drive it.

The rest of the original note still holds: `firmware/output/` has the five files
from a finished build, and it has not been flashed.

---

## Goal D — TX idle and unterminated-port protection

Run **first** — it protects the hardware steps in every other goal.
High risk: two consecutive clean adversarial reviews.

**Hardware limit, stated up front:** this board has no directional coupler and
no detector on the transmit port, so whether an antenna is attached to TX
cannot be measured by any means. The contract therefore does not try to detect
it. It gates on an explicit operator affirmation and shrinks the windows in
which an unterminated port is exposed. Adding a coupler and detector is the
only real fix, and that is a hardware change, not a firmware one.

```text
/goal Definition of done: the transmitter is provably silent in every idle condition on this board — from power-on through the init script, between streams, and after a stream ends abnormally — and no code path raises TX attenuation without a recorded operator affirmation that the port is terminated, verified by a continuous RX capture spanning a full power cycle through the TX1->RX1 loop (at least 20 dB of attenuation) showing nothing above the noise floor outside deliberate transmissions, by a table of stream-termination cases each read back from out_voltage0_hardwaregain and out_voltage1_hardwaregain at -89.75 dB, and by a demonstrated refusal of a TX-enabling call with no affirmation on record — while preserving the kernel's existing mute-on-stream-stop behaviour, the TX LO staying powered at boot, and every documented devkit command's behaviour, and staying within firmware/patches/, firmware/scripts/ and tools/.

Operating instructions: first read firmware/patches/0004-mute-tx-when-no-dma-stream.patch in full, including the tx_quiesce comment explaining why the TX LO is deliberately left up, and 0002-add-fishball-devicetree.patch for adi,tx-attenuation-mdB. Accept as a hardware fact that antenna presence on the TX port cannot be measured — this board has no coupler and no detector — so do not attempt to detect it; protect against it with an explicit affirmation gate and by minimising exposure windows instead. Keep the TX1->RX1 loop attached for every TX-enabling step in this work - at least 20 dB of attenuation, and cap transmit gain at -10 dB, which puts about -11 dBm at a receive port rated +2.5 dBm. Do not raise that cap to get a bigger reading. Enumerate the paths by which a stream can end — normal close, process kill, buffer underflow, network drop — and test each, reading attenuation back from sysfs rather than trusting that the call returned. Work one change at a time and re-run the affected case. After each failure update the hypothesis and make the smallest defensible next move. Maintain IDLE-CASES.md with one row per termination path: how it was induced, the attenuation read back, and whether RX saw anything. Do not power down the TX LO at boot. Do not remove, weaken or bypass tx_quiesce or its fw_setenv tx_quiesce escape hatch. Do not weaken the existing TX safety ramp. Do not default the affirmation to true and do not let it survive a reboot. Do not claim a quiet result from a single reading where a continuous capture is required. Do not flash via DFU — SD partition only. Do not transmit with the loop detached.

Verification: run each stream-termination case and quote the sysfs read-back before starting the capture work; then take the continuous RX capture across a full power cycle and quote its noise floor and peak; demonstrate the affirmation gate both refusing and accepting; require two consecutive adversarial reviews with no medium-or-above findings, restarting the count on any such finding; the reviewer must confirm the capture actually spans the boot window rather than starting after the init script has run.

Stop if the loop cannot be confirmed physically attached with at least 20 dB of attenuation, if the TX fault first seen at 18:30 on 2026-09-20 still prevents a carrier reaching the receiver and has not been resolved, if closing the boot window would require a device tree change that regresses RX or the mute path, or if a termination path cannot be induced on this hardware — report the cases covered, the read-backs, the blocker, evidence gathered, and the next input needed.

Completion receipt: print changed files, the IDLE-CASES.md table covering every termination path, the continuous capture's noise floor and peak with the command that produced it, the boot-window result, both affirmation-gate demonstrations, each command with its exit code, both review results, any exposure window left open with the reason, and remaining risks.
```

---

## Goal A — User-friendliness

Run second. Medium risk: one adversarial review.

```text
/goal Definition of done: a user starting from a fresh clone on a machine with no devkit state reaches a successfully flashed board at 192.168.2.1 without performing any step absent from the documentation and without reading the source, verified by a recorded clean-environment walkthrough in the transcript listing every command run and every point where the operator had to infer something, and by ./devkit doctor naming each missing prerequisite before the build starts rather than during it — while preserving every existing subcommand's name, arguments and exit codes, and staying within tools/, firmware/scripts/, devkit and docs/.

Operating instructions: first inspect ./devkit --help, tools/, firmware/scripts/, and the vendor's own user instructions at "/home/matthieu/Downloads/New version_7020_AD936X_SDR资料/新版7020_AD936X_SDR资料/Pluto固件相关/" (使用方法.txt, 使用方法1.txt, 使用方法2.txt, 出厂SD卡所带为固件1.txt) to identify which setup steps the vendor assumes and the devkit silently inherits. Then run the walkthrough in a container or scratch checkout with no prior state, recording each failure as a finding before fixing anything. Fix one friction point at a time and re-run the affected step. After each failure update the hypothesis and make the smallest defensible next move. Maintain WALKTHROUGH.md with one row per friction point: symptom, cause, fix, and whether the re-run cleared it. Do not document a step in place of removing it where removal is possible. Do not make ./devkit doctor pass by weakening a check. Do not rename a subcommand or change its arguments to make it read better. Do not flash via DFU — SD partition only. Do not transmit with any TX port unterminated.

Verification: re-run the full clean-environment walkthrough end to end after the final change and quote it; run ./devkit doctor on an environment deliberately missing a prerequisite and show it names that prerequisite; require one adversarial review asking which steps still depend on undocumented local state; confirm Host tools CI is green via gh run list.

Stop if a friction point cannot be fixed without changing a command's observable behaviour, if the walkthrough requires hardware that is unavailable or unsafe to drive, or if a clean environment cannot be constructed on this machine — report the friction log so far, the blocker, evidence gathered, and the next input needed.

Completion receipt: print changed files, the WALKTHROUGH.md table, the final clean-run transcript with exit codes, the doctor output on a deliberately incomplete environment, the review result, friction points found but deliberately not fixed with reasons, and remaining risks.
```

---

## Goal B — README and Claude skill

Run third. Medium risk: one adversarial review.

```text
/goal Definition of done: a reader with no prior exposure to this project completes the README's getting-started path unaided, and the fishball7020-firmware Claude skill routes an agent to the correct reference file for each workflow it documents, verified by a transcript of an agent with cleared context attempting both and logging every point it had to guess or consult source, and by every fenced command block in README.md, docs/ and .claude/skills/fishball7020-firmware/ carrying a "# run from:" line — while preserving the README's getting-started-only scope with depth living in docs/, the existing docs/ link structure, and agreement between every pin or connector claim and the vendor schematic, and staying within README.md, docs/ and .claude/skills/fishball7020-firmware/.

Operating instructions: first inspect README.md, docs/, .claude/skills/fishball7020-firmware/SKILL.md and its references/, and the vendor schematic at "/home/matthieu/Downloads/New version_7020_AD936X_SDR资料/新版7020_AD936X_SDR资料/硬件资料/7020_936x_SDR原理图.pdf" together with the factory acceptance document "7020-SDR专业版开箱检测.pdf". Cite the schematic for pin and connector facts rather than re-deriving them. Work one document at a time and re-run the cleared-context reader test after each. After each failure update the hypothesis and make the smallest defensible next move. Maintain GUESSES.md logging every point the test reader had to infer. Do not move reference depth into the README — it stays getting-started only. Do not drop a "# run from:" line from any command block. Do not introduce jargon without defining it at first use. Do not soften a measured claim into a vaguer one to avoid citing its source. Do not state a measurement the repo does not actually record.

Verification: run the cleared-context reader test for the README and separately for the skill, quoting both transcripts; grep every fenced command block in the changed files and show each carries its "# run from:" line; require one adversarial review asking which claims are asserted without a cited source; confirm no documentation claim contradicts the vendor schematic.

Stop if a documented claim cannot be reconciled with the vendor schematic, if getting-started cannot be completed without hardware that is unsafe or unavailable to drive, or if a fix would require moving reference depth into the README — report the guess log, the conflict, evidence gathered, and the next input needed.

Completion receipt: print changed files, GUESSES.md before and after, both reader-test transcripts, the "# run from:" grep output, the review result, claims left uncited with reasons, and remaining risks.
```

---

## Goal C — Efficiency

Run fourth (last). High risk: two consecutive clean adversarial reviews.

```text
/goal Definition of done: the devkit's FPGA build uses measurably fewer hardware resources or closes timing with more slack than the current HEAD baseline — at least one of LUT, FF, BRAM or DSP utilisation reduced, or worst negative slack increased, with no other metric regressed — verified by before-and-after figures quoted from firmware/output/utilization.rpt and timing.rpt for both builds, and by the board at 192.168.2.1 passing ./devkit verify --target factory --board, ./devkit sim --mutate, ./devkit gpio-check and ./devkit selftest after the change — while preserving every documented devkit command's behaviour and the sample-locked GPIO feature's measured properties, and staying within firmware/ and tools/ on a branch off main.

Operating instructions: before changing anything, run ./devkit build --target factory --hdl-only on unmodified HEAD and record baseline LUT/FF/BRAM/DSP and WNS figures from firmware/output/utilization.rpt and timing.rpt into a committed BASELINE.md; without that baseline no later claim is provable. For a second reference point, list (do not fully extract) the vendor designs at "/home/matthieu/Downloads/New version_7020_AD936X_SDR资料/新版7020_AD936X_SDR资料/Vivado2021.1工程/" — AD936X_PL.zip, AD936X_only_PL.zip — and note how the vendor's own resource figures compare where they are stated. Then work one change at a time: ./devkit sim, then ./devkit sim --mutate, then a full ./devkit build --target factory --hdl-only (~20 min), recording the same figures each round. After each failure or partial result, update the hypothesis and make the smallest defensible next move. Maintain BASELINE.md as a running table, one row per attempt, including attempts that regressed. Do not gain slack by loosening or deleting timing constraints, including patch 0009's CDC constraint. Do not gain utilisation by removing features, narrowing the GPIO nibble, or disabling the interpolator path. Do not weaken, skip or delete ./devkit sim --mutate. Do not flash via DFU — SD partition only. Do not transmit with any TX port unterminated: confirm an antenna or 50 ohm load is attached before any TX-enabling step, and do not bypass the TX safety ramp check. Treat the TX2A path as suspect until the user confirms that cable.

Verification: run ./devkit sim then ./devkit sim --mutate before any hardware step; after flashing run ./devkit verify --target factory --board, ./devkit gpio-check and ./devkit selftest and quote their output verbatim; require two consecutive adversarial reviews with no medium-or-above findings before declaring done, restarting the count on any such finding; the reviewer must confirm both figure sets came from the same build target through the same command, not from differently-configured runs.

Stop if the baseline build fails, if timing closes worse than HEAD and is not recovered within three attempts, if gpio-check or selftest regresses against its recorded pass, if any step would require TX while the antenna state is unconfirmed, or if no remaining candidate change improves a metric without regressing another. Report attempted paths, the figures for each, the blocker, unresolved findings, and the next input needed. Do not continue past that point on self-judged satisfaction.

Completion receipt: print changed files, the full BASELINE.md table including regressions, each command with its exit code, before-and-after utilisation and WNS figures, the verify --board, gpio-check and selftest output, both review results, what was not tested on air and why, and remaining risks.
```

---

## A note on what was deliberately removed

The original ask included "continue working until you are satisfied". That is a
self-judged stop condition, and it is the one clause that reliably defeats
everything else in a contract — an agent optimising against its own sense of
satisfaction either stops early or churns forever, and declares success either
way. Each goal instead ends on an external exhaustion test: no candidate change
left that improves a metric without regressing another (C), no friction point
left that the walkthrough surfaces (A), no guess left in the reader log (B).

Compiled 2026-09-20.
