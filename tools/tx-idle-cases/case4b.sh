#!/bin/sh
# run on the board. Case 4b: a TCP client of iiod has its connection
# BLACK-HOLED mid-stream - no FIN, no RST, socket left ESTABLISHED. Over
# loopback, because this board's Ethernet cannot keep the DAC fed at 3.072 MSPS
# (measured: the starve watchdog mutes within seconds with no drop involved), and
# a case that starves before the drop measures starvation, not a drop.
set -u
PHY=/sys/bus/iio/devices/iio:device0
DDS=/sys/bus/iio/devices/iio:device2
A0=$PHY/out_voltage0_hardwaregain
LOPD=$PHY/out_altvoltage1_TX_LO_powerdown
BUF=$DDS/buffer/enable
D=/tmp/drop4b; X=/tmp/exit4b; F=/tmp/fifo4b
up() { read _u _i < /proc/uptime; echo "$_u"; }
snap() { read _a0 < $A0; read _a1 < $PHY/out_voltage1_hardwaregain
         read _l < $LOPD; read _b < $BUF; read _u < $DDS/tx_dma_underflow_count
         printf '  up=%s atten0=%s atten1=%s LO_pd=%s buf=%s under=%s\n' \
            "$(up)" "$_a0" "$_a1" "$_l" "$_b" "$_u"; }

# 2000 ms, NOT the default 250. A network client on this board cannot keep the
# DAC fed reliably through stream start-up, so at 250 ms the watchdog fires
# BEFORE the drop and the case measures starvation - which is what the previous
# three attempts did. Raising the timeout makes the mute HARDER to achieve, not
# easier, so it is the conservative direction: the default protects sooner.
# Case 5 measures the same watchdog at the default 250 ms.
echo ${STARVE_MS:-2000} > $DDS/tx_starve_timeout_ms
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
sh /tmp/tx-guard.sh set-gain 0 -30; echo "  tx-guard exit=$?"
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
  echo "  kernel logged the mute at $KTS, drop was at $T0 -> $(awk -v a="$KTS" -v b="$T0" 'BEGIN{printf "%+.3f", a-b}') s"
  echo "  POSITIVE means the drop caused it. NEGATIVE means the stream had already starved"
  echo "  and this run proves nothing about the drop."
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
