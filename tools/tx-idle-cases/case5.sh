#!/bin/sh
# run on the board. Case 5: a LOCAL streaming client is SIGKILLed.
# No iiod, no network - iio_writedev on the local backend, which is the path
# firmware/patches/0015 exists for and the one IDLE-CASES.md never exercised.
set -u

# Whatever happens - abort, Ctrl-C, a failed assertion - leave the transmitter QUIET.
# These scripts raise TX to -30 dB, and the starve watchdog does not re-arm once it
# has fired, so an abort after that point used to exit with -30 dB still on the
# attenuator and nothing that would ever undo it. `revoke` is ungated and forces both
# channels to maximum attenuation, so it is safe to call from a trap.
# PIDs the script started, so the exit trap can end them. Without this, any abort
# after the writer starts - including assert_quiet's, which is the one most likely to
# fire - left a live stream behind, and `reap` then correctly DECLINED to touch it
# because an owner still held the fd. The mute landed; the stream did not stop.
WRITER=""; FEEDER=""
_kill_mine() {
  for _p in $WRITER $FEEDER; do kill -9 "$_p" 2>/dev/null; done
  [ -n "$WRITER$FEEDER" ] && sleep 1        # let the fd close before reap looks
}

_quiet_on_exit() {
  _kill_mine
  # Do NOT swallow this. tx-guard.sh prints FORCE-QUIET WRITE FAILED / PORT MAY BE LIVE
  # and returns 4 when it could not mute, and an emergency mute that fails silently is
  # worse than none. Also say so if the script was never pushed to the board.
  if [ ! -f /tmp/tx-guard.sh ]; then
    echo "*** /tmp/tx-guard.sh is not on the board - NOTHING WAS MUTED ***" >&2; return
  fi
  sh /tmp/tx-guard.sh revoke both || echo "*** EMERGENCY MUTE FAILED (exit $?) - TREAT THE PORTS AS LIVE ***" >&2
  # revoke mutes but does not disable a buffer, and a killed writer leaves one enabled -
  # which then trips the next run's "buffer already enabled" precondition. reap mutes
  # first and only then disables, so it is safe here and leaves the board re-runnable.
  sh /tmp/tx-guard.sh reap >/dev/null 2>&1
  case $? in 4) echo "*** REAP REPORTED A FAILURE - CHECK THE BOARD ***" >&2 ;; esac
}
# A buffer enable is itself a raise - the kernel restores a cached attenuation on it -
# so "the transmitter is still muted" has to be CHECKED, not printed. The harnesses'
# own exit trap runs `revoke both`, which leaves both channels at maximum and therefore
# ARMS that restore for the next run, so this is the likely case, not the exotic one.
report_and_mute_after_enable() {
  # A buffer enable is itself a raise: the kernel restores a cached attenuation on it.
  # For a TOOL that means to stay silent, that is a fault and it should abort - see
  # tx_gate.assert_quiet_after_enable. For a HARNESS that is about to raise through the
  # gate anyway it is an expected, documented phenomenon, and aborting on it makes the
  # harness unusable twice in a row: the previous run's own gain is what is in the cache.
  # So: say it happened, mute, verify the mute, and carry on. An UNREADABLE attenuator
  # is still fatal, because then nothing can be said about the state at all.
  _restored=""
  for _c in 0 1; do
    if ! read _a < "$PHY/out_voltage${_c}_hardwaregain" 2>/dev/null; then
      echo "ABORT: could not read channel $_c's attenuation after the buffer enable" >&2
      exit 4
    fi
    case "$_a" in -89.75*) ;; *) _restored="$_restored ch$_c=$_a" ;; esac
  done
  if [ -n "$_restored" ]; then
    echo "  NOTE: the buffer enable restored a cached gain:$_restored"
    echo "  (expected - the previous stream left it there. Muting before continuing.)"
    for _c in 0 1; do echo -89.75 > "$PHY/out_voltage${_c}_hardwaregain" 2>/dev/null; done
    for _c in 0 1; do
      read _a < "$PHY/out_voltage${_c}_hardwaregain" 2>/dev/null || { echo "ABORT: unreadable" >&2; exit 4; }
      case "$_a" in -89.75*) ;; *) echo "ABORT: ch$_c would not mute (reads $_a)" >&2; exit 4 ;; esac
    done
    echo "  both channels verified back at -89.75 dB"
  fi
}


PHY=/sys/bus/iio/devices/iio:device0
DDS=/sys/bus/iio/devices/iio:device2
A0=$PHY/out_voltage0_hardwaregain
A1=$PHY/out_voltage1_hardwaregain
LOPD=$PHY/out_altvoltage1_TX_LO_powerdown
BUF=$DDS/buffer/enable
trap '_quiet_on_exit' EXIT INT TERM

up() { read _u _i < /proc/uptime; echo "$_u"; }
snap() {
  read _a0 < $A0; read _a1 < $A1; read _lo < $LOPD; read _b < $BUF
  read _u < $DDS/tx_dma_underflow_count
  printf '  %8s  atten0=%s atten1=%s LO_pd=%s buf=%s underflows=%s\n' \
     "$(up)" "$_a0" "$_a1" "$_lo" "$_b" "$_u"
}
echo "kernel: $(uname -r)"
iio_attr -u local: -c ad9361-phy voltage0 sampling_frequency ${RATE:-3071997} >/dev/null 2>&1
echo "starve_timeout_ms=$(cat $DDS/tx_starve_timeout_ms)  cyclic_timeout_ms=$(cat $DDS/tx_cyclic_timeout_ms)"
echo "rate=$(cat $PHY/out_voltage_sampling_frequency)  TX_LO=$(cat $PHY/out_altvoltage1_TX_LO_frequency)"
echo "--- before anything ---"; snap
echo 0 > $DDS/tx_dma_underflow_count

F=/tmp/case5.fifo; rm -f $F; mkfifo $F || exit 1
# /dev/zero, not /dev/urandom: the DAC must stay FED while the writer is alive,
# or patch 0015 mutes it and the test measures starvation instead of the kill.
cat /dev/zero > $F 2>/dev/null & FEEDER=$!
iio_writedev -b 32768 -s 0 cf-ad9361-dds-core-lpc voltage0 voltage1 < $F > /dev/null 2>/tmp/case5.err & WRITER=$!
echo "feeder pid=$FEEDER  writer pid=$WRITER (LOCAL backend - no uri, no iiod)"

i=0
while :; do
  read _b < $BUF; [ "$_b" = "1" ] && break
  i=$((i+1)); [ $i -gt 100 ] && { echo "FAIL buffer never enabled"; cat /tmp/case5.err; exit 1; }
  sleep 0.05
done
report_and_mute_after_enable   # checked, not asserted in prose
echo "--- buffer up, transmitter verified still muted ---"; snap

# The ONLY raise in this test goes through the gate. No affirmation, no stream.
echo "--- raising through the gate: tx-guard set-gain 0 -30 ---"
if ! sh /tmp/tx-guard.sh set-gain 0 -30; then
  echo "  ABORT: the gate refused (run './devkit tx-guard affirm 0'). Without the raise"
  echo "  the transmitter never goes live and the poller matches on its first read."
  kill -9 $WRITER $FEEDER 2>/dev/null; exit 3
fi

echo "--- DURING the stream (this is what makes the re-mute mean anything) ---"
snap; sleep 1; snap; sleep 1; snap

echo "--- kill -9 both, then poll for the mute without sleeping ---"
S=$(up)
kill -9 $WRITER $FEEDER 2>/dev/null
MUTED=""; BUFAT=""
while :; do
  read _a0 < $A0
  case "$_a0" in -89.75*) read BUFAT < $BUF; MUTED=$(up); break;; esac
  read _n _i < /proc/uptime
  case "$(awk -v a="$_n" -v b="$S" 'BEGIN{print (a-b>10)?"to":"ok"}')" in to) break;; esac
done
if [ -n "$MUTED" ]; then
  echo "  muted after $(awk -v a="$MUTED" -v b="$S" 'BEGIN{printf "%.2f", a-b}') s"
  echo "  buffer/enable AT THE MOMENT OF THE MUTE: $BUFAT   <- 1 means the watchdog, not teardown"
else
  echo "  *** NOT MUTED within 10 s ***"
fi
echo "--- processes really gone? ---"
ps -o pid= -p $WRITER 2>/dev/null && echo "  writer STILL ALIVE" || echo "  writer $WRITER gone"
ps -o pid= -p $FEEDER 2>/dev/null && echo "  feeder STILL ALIVE" || echo "  feeder $FEEDER gone"
echo "--- after ---"; snap; sleep 1; snap
rm -f $F
echo "--- dmesg ---"
dmesg | grep -i "muting the transmitter" | tail -3
