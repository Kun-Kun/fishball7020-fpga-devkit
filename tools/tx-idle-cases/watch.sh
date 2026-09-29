#!/bin/sh
# run on the board. Poll as fast as the shell can for N seconds and report
# whether the TX buffer was EVER enabled and the loudest attenuation seen.
PHY=/sys/bus/iio/devices/iio:device0; DDS=/sys/bus/iio/devices/iio:device2
SECS="${1:-25}"; read T0 _ < /proc/uptime
BUF_EVER=0; LOUDEST=-89.75; LO_EVER=1; N=0
while :; do
  read b < $DDS/buffer/enable; [ "$b" = "1" ] && BUF_EVER=1
  read a < $PHY/out_voltage0_hardwaregain; a="${a%% *}"
  LOUDEST=$(awk -v x="$a" -v m="$LOUDEST" 'BEGIN{print (x>m)?x:m}')
  read l < $PHY/out_altvoltage1_TX_LO_powerdown; [ "$l" = "0" ] && LO_EVER=0
  N=$((N+1))
  read n _ < /proc/uptime
  [ "$(awk -v a="$n" -v b="$T0" -v s="$SECS" 'BEGIN{print (a-b>s)?1:0}')" = 1 ] && break
done
echo "  samples=$N over ${SECS}s  buffer_ever_enabled=$BUF_EVER  LO_ever_powered=$([ $LO_EVER = 0 ] && echo YES || echo no)  loudest_atten0=$LOUDEST"
