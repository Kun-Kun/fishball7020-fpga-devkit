source ../../scripts/adi_env.tcl
source $ad_hdl_dir/library/scripts/adi_ip_xilinx.tcl
adi_ip_create axis_tx_select
adi_ip_files axis_tx_select [list "axis_tx_select.v"]
adi_ip_properties_lite axis_tx_select
foreach {bus direction} {s_axis_tx1 slave s_axis_tx2 slave m_axis_tx1 master m_axis_tx2 master m_axis_ref master} {
  adi_add_bus $bus $direction \
    "xilinx.com:interface:axis_rtl:1.0" "xilinx.com:interface:axis:1.0" \
    [list [list "${bus}_tvalid" "TVALID"] \
          [list "${bus}_tready" "TREADY"] \
          [list "${bus}_tdata" "TDATA"]]
}
adi_add_bus_clock "clk" "s_axis_tx1:s_axis_tx2:m_axis_tx1:m_axis_tx2:m_axis_ref" "reset"
ipx::save_core [ipx::current_core]
