#!/bin/sh
# run on the board. Cases 1, 2 and 3, each with the attenuation read back DURING
# the stream - "muted afterwards" is worthless unless it was unmuted first.
set -u

# Whatever happens - abort, Ctrl-C, a failed assertion - leave the transmitter QUIET.
# These scripts raise TX to -30 dB, and the starve watchdog does not re-arm once it
# has fired, so an abort after that point used to exit with -30 dB still on the
# attenuator and nothing that would ever undo it. `revoke` is ungated and forces both
# channels to maximum attenuation, so it is safe to call from a trap.
_quiet_on_exit() { sh /tmp/tx-guard.sh revoke both >/dev/null 2>&1 || true; }

PHY=/sys/bus/iio/devices/iio:device0
DDS=/sys/bus/iio/devices/iio:device2
A0=$PHY/out_voltage0_hardwaregain
A1=$PHY/out_voltage1_hardwaregain
LOPD=$PHY/out_altvoltage1_TX_LO_powerdown
BUF=$DDS/buffer/enable
trap '_quiet_on_exit' EXIT INT TERM

up() { read _u _i < /proc/uptime; echo "$_u"; }
snap() { read _a0 < $A0; read _a1 < $A1; read _l < $LOPD; read _b < $BUF
         printf '  %-10s up=%s atten0=%s atten1=%s LO_pd=%s buf=%s\n' "$1" "$(up)" "$_a0" "$_a1" "$_l" "$_b"; }
wait_buf() { i=0; while :; do read _b < $BUF; [ "$_b" = "1" ] && return 0
             i=$((i+1)); [ $i -gt 80 ] && return 1; sleep 0.25; done; }
# Poll for the mute without sleeping, and report the kernel's own timestamp too.
wait_mute() { _t0="$1"; _m=""; while :; do read _a < $A0
    case "$_a" in -89.75*) read _b < $BUF; read _l < $LOPD; _m=$(up)
        printf '  muted %.2f s later; buffer/enable=%s LO_pd=%s\n' \
           "$(awk -v a="$_m" -v b="$_t0" 'BEGIN{print a-b}')" "$_b" "$_l"; return 0;; esac
    read _n _i < /proc/uptime
    [ "$(awk -v a="$_n" -v b="$_t0" 'BEGIN{print (a-b>15)?1:0}')" = 1 ] && {
        echo "  *** NOT MUTED within 15 s (atten0=$_a) ***"; return 1; }; done; }
iio_attr -u local: -c ad9361-phy voltage0 sampling_frequency ${RATE:-3071997} >/dev/null 2>&1
echo "starve_timeout_ms=$(cat $DDS/tx_starve_timeout_ms) rate=$(cat $PHY/out_voltage_sampling_frequency)"

############ case 1: NORMAL CLOSE - bounded write, exits by itself ############
echo; echo "=== CASE 1: normal close (local backend, -s bounded, exit 0) ==="
[ "$(cat $BUF)" = "0" ] || { echo "ABORT: buffer already enabled"; exit 2; }
snap before
F=/tmp/c1.fifo; rm -f $F; mkfifo $F
cat /dev/zero > $F 2>/dev/null & FE=$!
# ~2 s of samples, so there is a stream to look at while it runs.
iio_writedev -b 32768 -s 9216000 cf-ad9361-dds-core-lpc voltage0 voltage1 < $F >/dev/null 2>/tmp/c1.err & WR=$!
wait_buf || { echo "ABORT: buffer never came up"; cat /tmp/c1.err; exit 2; }
if ! sh /tmp/tx-guard.sh set-gain 0 -30; then
    echo "  ABORT: the gate refused (run './devkit tx-guard affirm 0'). Without the"
    echo "  raise the transmitter never goes live, the poller matches on its first"
    echo "  read, and a refusal is recorded as 'muted after 0.00 s'."; exit 3
  fi
snap DURING
T0=$(up)
wait $WR; echo "  iio_writedev exited $? (it closed the stream itself)"
kill -9 $FE 2>/dev/null
wait_mute "$T0"
snap after; rm -f $F

############ case 2: NETWORK client SIGKILLed - the FIN DOES arrive ############
echo; echo "=== CASE 2: network client killed (loopback iiod, socket closes: FIN) ==="
sh /tmp/tx-guard.sh reap >/dev/null 2>&1
snap before
F=/tmp/c2.fifo; rm -f $F; mkfifo $F
cat /dev/zero > $F 2>/dev/null & FE=$!
iio_writedev -u ip:127.0.0.1 -T 20000 -b 262144 -s 0 cf-ad9361-dds-core-lpc voltage0 voltage1 < $F >/dev/null 2>/tmp/c2.err & WR=$!
wait_buf || { echo "ABORT: buffer never came up"; cat /tmp/c2.err; exit 2; }
if ! sh /tmp/tx-guard.sh set-gain 0 -30; then
    echo "  ABORT: the gate refused (run './devkit tx-guard affirm 0'). Without the"
    echo "  raise the transmitter never goes live, the poller matches on its first"
    echo "  read, and a refusal is recorded as 'muted after 0.00 s'."; exit 3
  fi
snap DURING
read L < $LOPD
if [ "$L" != "0" ]; then echo "  NOTE: LO already down - this network stream starved before the kill"; fi
echo "  socket before the kill:"; ss -tn 2>/dev/null | grep 30431 | head -2 | sed 's/^/    /'
T0=$(up); kill -9 $WR $FE 2>/dev/null
wait_mute "$T0"
echo "  socket after:"; ss -tn 2>/dev/null | grep 30431 | head -2 | sed 's/^/    /' || echo "    (gone - iiod cleaned up)"
snap after; rm -f $F

############ case 3: STARVATION, client still alive and holding the buffer ####
echo; echo "=== CASE 3: starvation - buffer open, fed once, client ALIVE ==="
sh /tmp/tx-guard.sh reap >/dev/null 2>&1
snap before
F=/tmp/c3.fifo; rm -f $F; mkfifo $F
# Feeds 24 MB then goes quiet WITHOUT closing the fifo, so the writer blocks on
# read instead of seeing EOF: the buffer stays open with nothing arriving.
( head -c 25165824 /dev/zero; sleep 120 ) > $F 2>/dev/null & FE=$!
iio_writedev -b 32768 -s 0 cf-ad9361-dds-core-lpc voltage0 voltage1 < $F >/dev/null 2>/tmp/c3.err & WR=$!
wait_buf || { echo "ABORT: buffer never came up"; cat /tmp/c3.err; exit 2; }
if ! sh /tmp/tx-guard.sh set-gain 0 -30; then
    echo "  ABORT: the gate refused (run './devkit tx-guard affirm 0'). Without the"
    echo "  raise the transmitter never goes live, the poller matches on its first"
    echo "  read, and a refusal is recorded as 'muted after 0.00 s'."; exit 3
  fi
snap DURING
T0=$(up)
wait_mute "$T0"
kill -0 $WR 2>/dev/null && echo "  the client is STILL ALIVE and still owns the buffer" || echo "  client exited"
snap after
kill -9 $WR $FE 2>/dev/null; rm -f $F
sh /tmp/tx-guard.sh reap >/dev/null 2>&1
echo; echo "=== dmesg ==="; dmesg | grep "muting the transmitter" | tail -6
