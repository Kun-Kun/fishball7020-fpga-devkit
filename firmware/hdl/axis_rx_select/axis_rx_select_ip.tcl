source ../../scripts/adi_env.tcl
source $ad_hdl_dir/library/scripts/adi_ip_xilinx.tcl
adi_ip_create axis_rx_select
adi_ip_files axis_rx_select [list "axis_rx_select.v"]
adi_ip_properties_lite axis_rx_select
foreach {bus direction} {s_axis_raw slave m_axis_multiply master s_axis_product slave m_axis master} {
  adi_add_bus $bus $direction \
    "xilinx.com:interface:axis_rtl:1.0" "xilinx.com:interface:axis:1.0" \
    [list [list "${bus}_tvalid" "TVALID"] \
          [list "${bus}_tready" "TREADY"] \
          [list "${bus}_tdata" "TDATA"]]
}
adi_add_bus_clock "clk" "s_axis_raw:m_axis_multiply:s_axis_product:m_axis" "reset"
ipx::save_core [ipx::current_core]
