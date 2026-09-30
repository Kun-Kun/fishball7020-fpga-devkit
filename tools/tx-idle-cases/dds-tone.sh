#!/bin/sh
# run from: the board. Drive the FPGA's hardware DDS on one transmit chain.
#
#   sh dds-tone.sh <0|1> on     start a tone on TX1A (0) or TX2A (1)
#   sh dds-tone.sh <0|1> off    stop it and mute both channels
#
# WHY THIS IS THE MOST DANGEROUS SCRIPT HERE, and what has been done about it.
#
# It opens NO DMA buffer. That means neither patch 0004's stream-stop mute nor patch
# 0015's starve watchdog can ever reach it: there is no stream to stop and no data to
# stop arriving. An interrupted run therefore used to leave the tone up indefinitely at
# whatever attenuation was in force, with nothing in the firmware able to end it. It
# also powers the TX LO up by hand, and it can drive EITHER chain - including TX2A,
# which on some benches has an antenna on it.
#
# So: it now refuses without an affirmation for that channel, it traps its own exit to
# turn the tone off and mute both channels, and it leaves the TX LO powered down.
#
# DO NOT LAUNCH IT WITH `nohup`. Observed on this board: started as
# `nohup sh dds-tone.sh 1 on &` from an ssh command that then exited, the process
# later went away with the DDS scales STILL AT 0.25 and no exit line in its log - the
# trap did not run. Run it in the foreground, or `sh dds-tone.sh <ch> off` afterwards,
# which is authoritative and verifies what it did. POSIX shells will not install a
# trap for a signal that was ignored on entry, and `nohup` ignores SIGHUP, so the HUP
# arm of the trap is silently dropped under nohup.
# `tx-guard.sh` must be at /tmp/tx-guard.sh (./devkit tx-guard status puts it there).
set -u
P=/sys/bus/iio/devices/iio:device0
D=/sys/bus/iio/devices/iio:device2
PAIR="${1:?usage: dds-tone.sh <0|1> <on|off>}"
ACT="${2:?usage: dds-tone.sh <0|1> <on|off>}"
# VALIDATE THE ACTION. `if [ "$ACT" = off ]` alone is a literal lowercase match with no
# else, so EVERY other string fell through to the ENERGISE path: `OFF`, `Off`, `stop`,
# `0` and `"off "` all powered the TX LO up and wrote scale 0.25. The operator who types
# `dds-tone.sh 1 OFF` to stop a tone is holding a live affirmation, so the gate passes
# and the tone they asked to stop comes back on - on the one script no kernel mechanism
# can end. Unknown input must not resolve to the energising branch.
case "$ACT" in
  on|off) ;;
  *) echo "dds-tone: action must be exactly 'on' or 'off', got '$ACT'" >&2
     echo "dds-tone: refusing - an unrecognised action used to mean ON." >&2
     exit 1 ;;
esac
case "$PAIR" in 0) I=0; Q=2 ;; 1) I=4; Q=6 ;; *) echo "pair must be 0 (TX1A) or 1 (TX2A)" >&2; exit 1 ;; esac

# Mute both chains and PROVE it: write, read back, compare. A failed write here is the
# one failure in this script that leaves RF on the port, so it is never swallowed - it
# goes to stderr and it changes the exit status.
mute_both() {
  _bad=0
  for _c in 0 1; do
    if ! echo -89.75 > "$P/out_voltage${_c}_hardwaregain" 2>/dev/null; then
      echo "dds-tone: MUTE WRITE FAILED on channel $_c - assume TX$((_c+1))A IS LIVE" >&2
      _bad=1
      continue
    fi
    _rb=$(cat "$P/out_voltage${_c}_hardwaregain" 2>/dev/null)
    case "$_rb" in
      -89.7*) : ;;
      *) echo "dds-tone: channel $_c read back '${_rb:-unreadable}', not -89.75 - TX$((_c+1))A MAY BE LIVE" >&2
         _bad=1 ;;
    esac
  done
  return $_bad
}

# Zero EVERY DDS scale and PROVE it, the same write-read-compare the attenuators get.
#
# This matters more here than it does for the attenuators. A DDS tone is generated in
# the FPGA and radiates INDEPENDENTLY of the DMA path, so no kernel watchdog can end
# it - not the stream-stop mute, not the starve watchdog, not the cyclic bound. If
# this write fails and nobody looks, the only thing standing between the tone and the
# antenna is the attenuator, and the previous version of this function wrote the
# scales with 2>/dev/null and never read them back.
#
# All EIGHT, not just this run's pair: a tone left by an earlier run on the other
# chain is exactly as live, and this is the one place that reliably looks.
scales_off() {
  _bad=0
  for _c in 0 1 2 3 4 5 6 7; do
    _f=$(ls "$D"/out_altvoltage${_c}_*_scale 2>/dev/null) || continue
    [ -n "$_f" ] || continue
    if ! echo 0 > "$_f" 2>/dev/null; then
      echo "dds-tone: COULD NOT ZERO DDS scale $_c - A TONE MAY STILL BE RADIATING" >&2
      _bad=1; continue
    fi
    case "$(cat "$_f" 2>/dev/null)" in
      0|0.0|0.000000) : ;;
      *) echo "dds-tone: DDS scale $_c reads '$(cat "$_f" 2>/dev/null)', not 0 -" \
              "A TONE IS STILL BEING GENERATED" >&2
         _bad=1 ;;
    esac
  done
  return $_bad
}

# Returns nonzero if the tone could not be proven off OR a channel could not be
# proven muted. Both are reported; neither is swallowed.
tone_off() {
  scales_off
  _t=$?
  mute_both
  _m=$?
  echo 1 > "$P/out_altvoltage1_TX_LO_powerdown" 2>/dev/null
  [ $_t -eq 0 ] && [ $_m -eq 0 ]
}

if [ "$ACT" = off ]; then
  if tone_off; then
    echo "dds-tone: off, both channels read back muted, TX LO down"; exit 0
  fi
  echo "dds-tone: off requested but the mute could NOT be verified - see above" >&2; exit 5
fi

# The gate, before anything is energised. This script raises output on a named port and
# nothing else here can stop it, so an affirmation is the minimum.
if [ ! -f /tmp/tx-guard.sh ]; then
  echo "dds-tone: /tmp/tx-guard.sh is not on the board; run './devkit tx-guard status' first" >&2; exit 4
fi
if ! sh /tmp/tx-guard.sh check "$PAIR"; then
  echo "dds-tone: REFUSED - no affirmation on record for channel $PAIR." >&2
  echo "dds-tone: look at that port, then './devkit tx-guard affirm $PAIR'." >&2
  exit 3
fi

# From here on, any exit leaves the tone off and both channels muted.
# HUP matters as much as INT here: this is normally run over ssh, and a dropped session
# delivers HUP, not INT. Without it the shell dies untrapped and the tone stays up with
# nothing in the firmware able to end it.
_on_exit() {
  if tone_off; then
    echo "dds-tone: exited - tone off, both channels read back muted" >&2
  else
    echo "dds-tone: exited - MUTE NOT VERIFIED, treat both ports as live" >&2
  fi
}
# PIPE and QUIT for the same reason as HUP: dash runs the EXIT trap for none of
# them. QUIT is what an operator reaches for (Ctrl-\) when Ctrl-C looks stuck.
# MEASURED ON THIS BOARD, not assumed: with the list below, TERM, HUP and PIPE all run
# the trap. QUIT does NOT - dash accepts the trap (it lists in `trap`) and then dies
# without running it, twice out of two. QUIT is kept because it costs nothing and works
# under a /bin/sh that is not dash, but do not count on it here: Ctrl-\ on this board
# leaves the transmitter up. Ctrl-C (INT) is trapped and is the one to use.
trap _on_exit EXIT INT TERM HUP PIPE QUIT

echo 0 > "$P/out_altvoltage1_TX_LO_powerdown"
for c in $I $Q; do
  echo 400000 > "$(ls $D/out_altvoltage${c}_*_frequency)"
  echo 0.25   > "$(ls $D/out_altvoltage${c}_*_scale)"
done
echo 90000 > "$(ls $D/out_altvoltage${I}_*_phase)"
echo 0     > "$(ls $D/out_altvoltage${Q}_*_phase)"
printf 'dds-tone: TX%s tone at 400 kHz, scale 0.25, LO_pd=%s. Attenuation is still yours\n' \
  "$((PAIR+1))" "$(cat $P/out_altvoltage1_TX_LO_powerdown)"
printf 'dds-tone: to raise output use the gate: sh /tmp/tx-guard.sh set-gain %s <dB>\n' "$PAIR"
echo "dds-tone: Ctrl-C or any exit turns the tone off and mutes both channels."
# Hold, so the trap is what ends it rather than the script simply returning with the
# DDS still running.
while :; do sleep 1; done
