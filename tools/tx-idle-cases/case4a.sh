#!/bin/bash
# run from: the repo root, on the HOST. Case 4a: a network streaming client's
# NETWORK goes away - no FIN, no RST, iiod's socket left ESTABLISHED.
set -u
S="$1"; RATE="$2"; PORT="$3"; TAG="$4"
B=fishball
PHY=/sys/bus/iio/devices/iio:device0
DDS=/sys/bus/iio/devices/iio:device2
bsh() { ssh -o BatchMode=yes $B "$@"; }
snap() { bsh "printf '  up=%s atten0=%s atten1=%s LO_pd=%s buf=%s under=%s\n' \
    \"\$(cut -d' ' -f1 /proc/uptime)\" \"\$(cat $PHY/out_voltage0_hardwaregain)\" \
    \"\$(cat $PHY/out_voltage1_hardwaregain)\" \"\$(cat $PHY/out_altvoltage1_TX_LO_powerdown)\" \
    \"\$(cat $DDS/buffer/enable)\" \"\$(cat $DDS/tx_dma_underflow_count)\""; }
D="$S/drop.$TAG"; X="$S/exit.$TAG"; L="$S/relay.$TAG.log"; F="$S/fifo.$TAG"
rm -f "$D" "$X" "$L" "$F"; mkfifo "$F"

bsh "iio_attr -u local: -c ad9361-phy voltage0 sampling_frequency $RATE >/dev/null 2>&1
     echo 0 > $DDS/tx_dma_underflow_count"
echo "rate=$(bsh "cat $PHY/out_voltage_sampling_frequency")  starve_timeout_ms=$(bsh "cat $DDS/tx_starve_timeout_ms")"
echo "--- before anything ---"; snap
[ "$(bsh "cat $DDS/buffer/enable")" = "0" ] || { echo "ABORT: a TX buffer is already enabled; run './devkit tx-guard reap'"; exit 2; }

./tools/tcp-blackhole.py --to fishball.local:30431 --listen 127.0.0.1:$PORT \
    --drop-when "$D" --exit-when "$X" --sndbuf ${SNDBUF:-131072} --chunk ${CHUNK:-1048576} > "$L" 2>&1 &
RELAY=$!; sleep 1
cat /dev/zero > "$F" 2>/dev/null & FEEDER=$!
iio_writedev -u ip:127.0.0.1:$PORT -T 20000 -b 262144 -s 0 \
    cf-ad9361-dds-core-lpc voltage0 voltage1 < "$F" >/dev/null 2>"$S/we.$TAG" & WRITER=$!
echo "relay=$RELAY feeder=$FEEDER writer=$WRITER (network backend, through the relay)"

for i in $(seq 60); do [ "$(bsh "cat $DDS/buffer/enable")" = "1" ] && break; sleep 0.2; done
kill -0 $WRITER 2>/dev/null || { echo "ABORT: writer died before streaming:"; cat "$S/we.$TAG"; exit 2; }
echo "--- buffer up (nothing has asked for gain yet) ---"; snap

echo "--- raising through the gate ---"
./devkit tx-guard set-gain 0 -30; echo "  tx-guard exit=$?"
echo "--- DURING the stream. LO_pd MUST read 0 here or the stream already starved ---"
snap; sleep 2; snap; sleep 2; snap
LOPD=$(bsh "cat $PHY/out_altvoltage1_TX_LO_powerdown")
SM=$(bsh "dmesg | grep -c 'muting the transmitter'")
if [ "$LOPD" != "0" ] || [ "$SM" != "0" ]; then
  echo "ABORT: not live at the drop (LO_pd=$LOPD, starve mutes so far=$SM)."
  echo "The stream starved before the drop, so this would measure starvation, not a drop."
  kill -9 $WRITER $FEEDER 2>/dev/null; touch "$D"; sleep 0.3; touch "$X"; sleep 0.5; kill -9 $RELAY 2>/dev/null
  exit 3
fi
echo "  LIVE: LO_pd=0 and no starve mute yet"
echo "--- the board's view of the connection while it is healthy ---"
bsh "ss -tnp 2>/dev/null | grep 30431"
H0=$(date +%s.%N); U0=$(bsh "cut -d' ' -f1 /proc/uptime"); H1=$(date +%s.%N)
echo "--- clock map: host $H0 .. $H1 <-> board uptime $U0 ---"

bsh "nohup sh /tmp/case4-poller.sh > /tmp/case4.out 2>&1 &"; sleep 0.5
kill -0 $WRITER 2>/dev/null || { echo "ABORT: writer not alive at the drop"; exit 2; }
DROP=$(date +%s.%N); touch "$D"
echo "--- DROPPED at host $DROP (writer $WRITER was alive) ---"
kill -9 $WRITER $FEEDER 2>/dev/null
sleep 6
echo "--- poller result ---"; bsh "cat /tmp/case4.out"
echo "--- after the mute, relay STILL holding the board sockets open ---"; snap
bsh "ss -tnp 2>/dev/null | grep 30431 || echo '(no connection on 30431)'"
echo "--- now close the sockets and watch iiod tidy up ---"
touch "$X"; sleep 3; snap
bsh "ss -tnp 2>/dev/null | grep 30431 || echo '(no connection on 30431)'"
echo "--- dmesg ---"; bsh "dmesg | grep 'muting the transmitter'"
echo "--- relay log ---"; cat "$L"
rm -f "$F"
