source ../../scripts/adi_env.tcl
source $ad_hdl_dir/library/scripts/adi_ip_xilinx.tcl
adi_ip_create axis_split
adi_ip_files axis_split [list "axis_split.v"]
adi_ip_properties_lite axis_split
foreach {bus direction} {s_axis slave m_axis_0 master m_axis_1 master} {
  adi_add_bus $bus $direction \
    "xilinx.com:interface:axis_rtl:1.0" "xilinx.com:interface:axis:1.0" \
    [list [list "${bus}_tvalid" "TVALID"] \
          [list "${bus}_tready" "TREADY"] \
          [list "${bus}_tdata" "TDATA"]]
}
adi_add_bus_clock "clk" "s_axis:m_axis_0:m_axis_1" "reset"
ipx::save_core [ipx::current_core]
