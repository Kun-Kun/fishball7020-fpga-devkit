#!/bin/sh
# run on the board. Case 4b: a TCP client of iiod has its connection
# BLACK-HOLED mid-stream - no FIN, no RST, socket left ESTABLISHED. Over
# loopback, because this board's Ethernet cannot keep the DAC fed at 3.072 MSPS
# (measured: the starve watchdog mutes within seconds with no drop involved), and
# a case that starves before the drop measures starvation, not a drop.
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
LOPD=$PHY/out_altvoltage1_TX_LO_powerdown
BUF=$DDS/buffer/enable
D=/tmp/drop4b; X=/tmp/exit4b; F=/tmp/fifo4b
trap '_quiet_on_exit' EXIT INT TERM

up() { read _u _i < /proc/uptime; echo "$_u"; }
snap() { read _a0 < $A0; read _a1 < $PHY/out_voltage1_hardwaregain
         read _l < $LOPD; read _b < $BUF; read _u < $DDS/tx_dma_underflow_count
         printf '  up=%s atten0=%s atten1=%s LO_pd=%s buf=%s under=%s\n' \
            "$(up)" "$_a0" "$_a1" "$_l" "$_b" "$_u"; }

# THE DEFAULT, 250 ms. An earlier version of this script defaulted to 2000 and
# carried a comment claiming the board could not keep a network stream fed at the
# default - both retracted: the bottleneck was tcp-blackhole.py copying 64 KB at a
# time, and with --chunk 1048576 this runs at 250 ms. Leaving 2000 here meant the
# committed harness reproduced the superseded configuration while the table quoted
# the default. The previous value is restored on the way out, however this exits.
ORIG_STARVE=$(cat $DDS/tx_starve_timeout_ms)
trap 'echo "$ORIG_STARVE" > '"$DDS"'/tx_starve_timeout_ms 2>/dev/null' EXIT INT TERM
echo ${STARVE_MS:-250} > $DDS/tx_starve_timeout_ms
iio_attr -u local: -c ad9361-phy voltage0 sampling_frequency ${RATE:-3071997} >/dev/null 2>&1
echo "starve_timeout_ms=$(cat $DDS/tx_starve_timeout_ms)  rate=$(cat $PHY/out_voltage_sampling_frequency)"
rm -f $D $X $F
echo "--- before anything ---"; snap
[ "$(cat $BUF)" = "0" ] || { echo "ABORT: a TX buffer is already enabled - reap it first"; exit 2; }
echo 0 > $DDS/tx_dma_underflow_count
dmesg -C

python3 /tmp/tcp-blackhole.py --to 127.0.0.1:30431 --listen 127.0.0.1:34340 \
    --drop-when $D --exit-when $X --sndbuf ${SNDBUF:-131072} --chunk ${CHUNK:-1048576} > /tmp/relay4b.log 2>&1 &
RELAY=$!
sleep 2
mkfifo $F
cat /dev/zero > $F 2>/dev/null & FEEDER=$!
iio_writedev -u ip:127.0.0.1:34340 -T 20000 -b 262144 -s 0 \
    cf-ad9361-dds-core-lpc voltage0 voltage1 < $F > /dev/null 2>/tmp/we4b & WRITER=$!
echo "relay=$RELAY feeder=$FEEDER writer=$WRITER  (TCP client of iiod, via the relay)"

i=0
while :; do read _b < $BUF; [ "$_b" = "1" ] && break
  i=$((i+1)); [ $i -gt 120 ] && { echo "ABORT: buffer never enabled"; cat /tmp/we4b; exit 2; }
  sleep 0.25; done
kill -0 $WRITER 2>/dev/null || { echo "ABORT: writer died before streaming"; cat /tmp/we4b; exit 2; }
echo "--- buffer up (nothing has asked for gain yet) ---"; snap

echo "--- raising through the gate ---"
if ! sh /tmp/tx-guard.sh set-gain 0 -30; then
  echo "ABORT: the gate refused the raise (exit $?). Run './devkit tx-guard affirm 0'."
  echo "Without this the transmitter never goes live and every reading below would be"
  echo "a muted board agreeing with itself - which is how a refusal gets recorded as a"
  echo "measurement."
  kill -9 $WRITER $FEEDER 2>/dev/null; touch $D; sleep 0.5; touch $X; sleep 1
  kill -9 $RELAY 2>/dev/null; rm -f $F; exit 3
fi
# ONE snapshot, then drop at once. The stream stays healthy for a couple of
# seconds and no longer - this board cannot keep a network TX stream fed
# indefinitely at 3.072 MSPS - so spending that window on snapshots is what made
# the earlier attempts measure starvation instead of a drop.
echo "--- DURING the stream: LO_pd must be 0 and no starve mute yet ---"
snap
read L < $LOPD; SM=$(dmesg | grep -c "muting the transmitter")
if [ "$L" != "0" ] || [ "$SM" != "0" ]; then
  echo "ABORT: not live at the drop (LO_pd=$L starve_mutes=$SM) - this would measure starvation"
  kill -9 $WRITER $FEEDER 2>/dev/null; touch $D; sleep 0.5; touch $X; sleep 1; kill -9 $RELAY 2>/dev/null
  rm -f $F; exit 3
fi
echo "  LIVE at the drop: LO_pd=0, atten0=$(cat $A0), no starve mute yet"

# The drop, then poll for the mute WITHOUT sleeping. Everything is local here,
# so the elapsed time is measured from the touch itself.
read AB < $A0
echo "  atten0 immediately before the drop: $AB"
# Assert it is LOUD. LO_pd reads 0 whenever a buffer is enabled, whatever the
# attenuation, so the liveness guard above cannot catch a transmitter that is
# muted-but-streaming - and a muted board mutes again instantly, giving a delta of
# 0.00 s that looks like a perfect result.
case "$AB" in -89.75*)
  echo "ABORT: the transmitter is at maximum attenuation at the moment of the drop."
  echo "There is nothing to mute, so any delta measured here would be meaningless."
  kill -9 $WRITER $FEEDER 2>/dev/null; touch $D; sleep 0.5; touch $X; sleep 1
  kill -9 $RELAY 2>/dev/null; rm -f $F; exit 3;;
esac
T0=$(up)
touch $D
kill -9 $WRITER $FEEDER 2>/dev/null
MUTED=""; BUFAT=""; LOAT=""
while :; do
  read A < $A0
  case "$A" in -89.75*) read BUFAT < $BUF; read LOAT < $LOPD; MUTED=$(up); break;; esac
  read N _ < /proc/uptime
  [ "$(awk -v a="$N" -v b="$T0" 'BEGIN{print (a-b>20)?1:0}')" = 1 ] && break
done
echo "--- DROPPED at board uptime $T0, client killed ---"
if [ -n "$MUTED" ]; then
  echo "  MUTED $(awk -v a="$MUTED" -v b="$T0" 'BEGIN{printf "%.2f", a-b}') s after the drop"
  echo "  buffer/enable at the mute: $BUFAT     <- 1 = the kernel watchdog, not teardown"
  echo "  TX_LO_powerdown at the mute: $LOAT"
else
  echo "  *** NOT MUTED within 20 s ***"
fi
echo "--- the kernel's OWN timestamp for the mute, against the drop at $T0 ---"
dmesg | grep "muting the transmitter" | tail -2
KTS=$(dmesg | grep "muting the transmitter" | tail -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/')
if [ -n "$KTS" ]; then
  # printk and /proc/uptime are NOT the same clock - printk runs about 0.077 s
  # behind on this board - so this line is corroboration that the watchdog is what
  # fired, NOT a delta. The delta above is uptime-against-uptime.
  echo "  kernel's own log line at printk $KTS (a different clock from /proc/uptime;"
  echo "  printk lags by about 0.077 s here, so do not subtract these two)"
fi
# The watchdog fires TIMEOUT after the last submitted block, and the last block
# precedes the drop, so 0 < delta <= timeout always. A delta at or near ZERO means
# the mute was already pending when the trigger was pulled.
if [ -n "$MUTED" ]; then
  echo "  criterion: 0 < delta <= $(cat $DDS/tx_starve_timeout_ms) ms expected;"
  echo "  a delta at or near ZERO disqualifies the run - the stream had already starved."
fi
echo "--- iiod's sockets AT/AFTER the mute (relay still holding them open) ---"
ss -tnp 2>/dev/null | grep 30431 || echo "  (no connection on 30431)"
snap
echo "--- now close the sockets; iiod should tear the buffer down ---"
touch $X; sleep 3; snap
ss -tnp 2>/dev/null | grep 30431 || echo "  (no connection on 30431)"
echo "--- dmesg ---"; dmesg | grep "muting the transmitter"
echo "--- relay log ---"; cat /tmp/relay4b.log
rm -f $F
