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
# `tx-guard.sh` must be at /tmp/tx-guard.sh (./devkit tx-guard status puts it there).
set -u
P=/sys/bus/iio/devices/iio:device0
D=/sys/bus/iio/devices/iio:device2
PAIR="${1:?usage: dds-tone.sh <0|1> <on|off>}"
ACT="${2:?usage: dds-tone.sh <0|1> <on|off>}"
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

# Returns nonzero if either channel could not be proven muted.
tone_off() {
  for c in $I $Q; do echo 0 > "$(ls $D/out_altvoltage${c}_*_scale)" 2>/dev/null; done
  mute_both
  _muted=$?
  echo 1 > "$P/out_altvoltage1_TX_LO_powerdown" 2>/dev/null
  return $_muted
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
trap _on_exit EXIT INT TERM HUP

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
