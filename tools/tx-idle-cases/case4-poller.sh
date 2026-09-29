#!/bin/sh
# run on the board. Waits for a loud->quiet transition on one transmit chain and
# records everything at that instant, including whether iiod's socket is still up.
#
#   sh case4-poller.sh <0|1>     0 = TX1A, 1 = TX2A
#
# The channel is required. This one only watches - it never raises anything - but
# watching the wrong port is how a run gets recorded as "muted after 0.00 s": the
# idle channel matches on the first read and the loud one is never looked at.
PAIR="${1:-}"
case "$PAIR" in
  0|1) ;;
  *) echo "usage: sh case4-poller.sh <0|1>   (0 = TX1A, 1 = TX2A)" >&2; exit 1 ;;
esac
PHY=/sys/bus/iio/devices/iio:device0
DDS=/sys/bus/iio/devices/iio:device2
A0=$PHY/out_voltage${PAIR}_hardwaregain
BUF=$DDS/buffer/enable
SEEN=0
read S0 _ < /proc/uptime
while :; do
  read A < $A0
  case "$A" in
    -89.75*) if [ "$SEEN" = 1 ]; then
               read B < $BUF; read U _ < /proc/uptime
               echo "MUTED_AT_UPTIME=$U"
               echo "BUFFER_ENABLE_AT_MUTE=$B"
               echo "ATTEN${PAIR}_AT_MUTE=$A"
               echo "LO_PD_AT_MUTE=$(cat $PHY/out_altvoltage1_TX_LO_powerdown)"
               echo "--- iiod sockets at the moment of the mute ---"
               ss -tnp 2>/dev/null | grep -E '30431|iiod' || echo "(none)"
               exit 0
             fi ;;
    *) SEEN=1 ;;
  esac
  read N _ < /proc/uptime
  [ "$(awk -v a="$N" -v b="$S0" 'BEGIN{print (a-b>30)?1:0}')" = 1 ] && {
      echo "NEVER_MUTED within 30 s (last atten$PAIR=$A seen_loud=$SEEN)"; exit 1; }
done
