# ***************************************************************************
# Copyright (C) 2026 Fishball
# SPDX short identifier: BSD-1-Clause
# ***************************************************************************

source ../../scripts/adi_env.tcl
source $ad_hdl_dir/library/scripts/adi_ip_xilinx.tcl

adi_ip_create util_cpack2_axis
adi_ip_files util_cpack2_axis [list \
  "ad_perfect_shuffle.v" \
  "pack_ctrl.v" \
  "pack_interconnect.v" \
  "pack_network.v" \
  "pack_shell.v" \
  "util_cpack2_impl.v" \
  "util_cpack2_axis.v" ]
adi_ip_properties_lite util_cpack2_axis

# `overflow` is intentionally a scalar status port. The ADI FIFO interface
# inference sees that name and creates an incomplete legacy fifo_wr interface
# before the explicit AXIS interfaces below are added.
set cc [ipx::current_core]
set inferred_fifo [ipx::get_bus_interfaces interface_fifo_wr -of_objects $cc]
if {$inferred_fifo ne ""} {
  ipx::remove_bus_interface $inferred_fifo
}

set axis_bus_names {m_axis}
for {set i 0} {$i < 32} {incr i} {
  set bus "s_axis_$i"
  adi_add_bus $bus "slave" \
    "xilinx.com:interface:axis_rtl:1.0" \
    "xilinx.com:interface:axis:1.0" \
    [list \
      [list "s_axis_${i}_tdata" "TDATA"] \
      [list "s_axis_${i}_tvalid" "TVALID"] \
      [list "s_axis_${i}_tready" "TREADY"]]
  set_property enablement_dependency \
    "spirit:decode(id('MODELPARAM_VALUE.NUM_OF_CHANNELS')) > $i" \
    [ipx::get_bus_interfaces $bus -of_objects [ipx::current_core]]
  lappend axis_bus_names $bus
}

adi_add_bus "m_axis" "master" \
  "xilinx.com:interface:axis_rtl:1.0" \
  "xilinx.com:interface:axis:1.0" \
  {
    {"m_axis_tdata" "TDATA"} \
    {"m_axis_tvalid" "TVALID"} \
    {"m_axis_tready" "TREADY"} \
  }
adi_add_bus_clock "clk" [join $axis_bus_names ":"] "reset"

for {set i 0} {$i < 64} {incr i} {
  set_property enablement_dependency "spirit:decode(id('MODELPARAM_VALUE.NUM_OF_CHANNELS')) > $i" \
    [ipx::get_ports enable_$i -of_objects $cc]
}
foreach {k v} {
  "NUM_OF_CHANNELS" "Number of Channels"
  "SAMPLES_PER_CHANNEL" "Samples per Channel"
  "SAMPLE_DATA_WIDTH" "Sample Width"
} {
  set p [ipgui::get_guiparamspec -name $k -component $cc]
  set_property DISPLAY_NAME $v $p
}
ipx::save_core [ipx::current_core]
