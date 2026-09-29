#!/bin/sh
# $1 = pair (0|1), $2 = on|off. Drives the FPGA's hardware DDS, no DMA.
D=/sys/bus/iio/devices/iio:device2; P=/sys/bus/iio/devices/iio:device0
if [ "$1" = 1 ]; then I=4; Q=6; else I=0; Q=2; fi
if [ "$2" = on ]; then
  echo 0 > $P/out_altvoltage1_TX_LO_powerdown
  for c in $I $Q; do echo 400000 > $(ls $D/out_altvoltage${c}_*_frequency); echo 0.25 > $(ls $D/out_altvoltage${c}_*_scale); done
  echo 90000 > $(ls $D/out_altvoltage${I}_*_phase); echo 0 > $(ls $D/out_altvoltage${Q}_*_phase)
else
  for c in $I $Q; do echo 0 > $(ls $D/out_altvoltage${c}_*_scale); done
  echo 1 > $P/out_altvoltage1_TX_LO_powerdown
fi
