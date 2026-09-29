#!/bin/sh
# run on the board. Case 5: a LOCAL streaming client is SIGKILLed.
# No iiod, no network - iio_writedev on the local backend, which is the path
# firmware/patches/0015 exists for and the one IDLE-CASES.md never exercised.
set -u
PHY=/sys/bus/iio/devices/iio:device0
DDS=/sys/bus/iio/devices/iio:device2
A0=$PHY/out_voltage0_hardwaregain
A1=$PHY/out_voltage1_hardwaregain
LOPD=$PHY/out_altvoltage1_TX_LO_powerdown
BUF=$DDS/buffer/enable
up() { read _u _i < /proc/uptime; echo "$_u"; }
snap() {
  read _a0 < $A0; read _a1 < $A1; read _lo < $LOPD; read _b < $BUF
  read _u < $DDS/tx_dma_underflow_count
  printf '  %8s  atten0=%s atten1=%s LO_pd=%s buf=%s underflows=%s\n' \
     "$(up)" "$_a0" "$_a1" "$_lo" "$_b" "$_u"
}
echo "kernel: $(uname -r)"
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
echo "--- buffer up, transmitter still muted (nothing has raised it) ---"; snap

# The ONLY raise in this test goes through the gate. No affirmation, no stream.
echo "--- raising through the gate: tx-guard set-gain 0 -30 ---"
sh /tmp/tx-guard.sh set-gain 0 -30; echo "  tx-guard exit=$?"

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
