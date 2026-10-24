source ../../scripts/adi_env.tcl
source $ad_hdl_dir/library/scripts/adi_ip_xilinx.tcl

adi_ip_create util_upack2_axis
adi_ip_files util_upack2_axis [list "util_upack2_axis.v"]
adi_ip_properties_lite util_upack2_axis
set cc [ipx::current_core]
set_property -dict [list \
  value_validation_type list \
  value_validation_list {1 2}] \
  [ipx::get_user_parameters NUM_OF_CHANNELS -of_objects $cc]
set p [ipgui::get_guiparamspec -name NUM_OF_CHANNELS -component $cc]
set_property DISPLAY_NAME "Number of Channels" $p
adi_add_bus "s_axis" "slave" \
  "xilinx.com:interface:axis_rtl:1.0" \
  "xilinx.com:interface:axis:1.0" \
  [list {"s_axis_ready" "TREADY"} \
    {"s_axis_valid" "TVALID"} \
    {"s_axis_data" "TDATA"}]

foreach n {0 1} {
  adi_add_bus "m_axis_$n" "master" \
    "xilinx.com:interface:axis_rtl:1.0" \
    "xilinx.com:interface:axis:1.0" \
    [list [list "m_axis_${n}_tdata" "TDATA"] \
      [list "m_axis_${n}_tvalid" "TVALID"] \
      [list "m_axis_${n}_tready" "TREADY"]]
  if {$n > 0} {
    set bus_if [ipx::get_bus_interfaces "m_axis_$n" -of_objects [ipx::current_core]]
    set_property enablement_dependency \
      "spirit:decode(id('MODELPARAM_VALUE.NUM_OF_CHANNELS')) > $n" $bus_if
  }
}
adi_add_bus_clock "clk" "s_axis:m_axis_0:m_axis_1" "reset"
ipx::save_core [ipx::current_core]
