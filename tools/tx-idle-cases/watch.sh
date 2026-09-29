#!/bin/sh
# run on the board. Poll as fast as the shell can for N seconds and report
# whether the TX buffer was EVER enabled and the loudest attenuation seen.
PHY=/sys/bus/iio/devices/iio:device0; DDS=/sys/bus/iio/devices/iio:device2
SECS="${1:-25}"; read T0 _ < /proc/uptime
# LOUDEST starts BELOW maximum attenuation, not at it, and an unreadable value is
# recorded as UNREADABLE rather than skipped. Starting at -89.75 and ignoring a
# failed read meant a channel that could not be read was reported as quiet - the
# exact inversion this script is supposed to detect.
BUF_EVER=0; LOUDEST=-200; LO_EVER=1; N=0; UNREADABLE=0
while :; do
  read b < $DDS/buffer/enable; [ "$b" = "1" ] && BUF_EVER=1
  # BOTH channels: channel 1 is a separate SMA port, and on this bench it is the
  # one with an antenna on it.
  for _c in 0 1; do
    if read a < $PHY/out_voltage${_c}_hardwaregain 2>/dev/null; then
      a="${a%% *}"
      case "$a" in ''|*[!0-9.eE+-]*) UNREADABLE=1;;
        *) LOUDEST=$(awk -v x="$a" -v m="$LOUDEST" 'BEGIN{print (x>m)?x:m}');; esac
    else UNREADABLE=1; fi
  done
  read l < $PHY/out_altvoltage1_TX_LO_powerdown; [ "$l" = "0" ] && LO_EVER=0
  N=$((N+1))
  read n _ < /proc/uptime
  [ "$(awk -v a="$n" -v b="$T0" -v s="$SECS" 'BEGIN{print (a-b>s)?1:0}')" = 1 ] && break
done
echo "  samples=$N over ${SECS}s  buffer_ever_enabled=$BUF_EVER  LO_ever_powered=$([ $LO_EVER = 0 ] && echo YES || echo no)  loudest_atten_either_channel=$LOUDEST  unreadable_at_any_point=$UNREADABLE"
[ "$UNREADABLE" = "1" ] && echo "  *** an attenuator could not be read at least once - this run proves nothing ***"
exit 0
