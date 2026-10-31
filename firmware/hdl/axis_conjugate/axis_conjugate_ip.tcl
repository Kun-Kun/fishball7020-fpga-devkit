# **************************************************************************
# Copyright (C) 2026 Fishball
# SPDX-License-Identifier: BSD-1-Clause
# **************************************************************************

source ../../scripts/adi_env.tcl
source $ad_hdl_dir/library/scripts/adi_ip_xilinx.tcl

adi_ip_create axis_conjugate
adi_ip_files axis_conjugate [list "axis_conjugate.v"]
adi_ip_properties_lite axis_conjugate

adi_add_bus "s_axis" "slave" \
  "xilinx.com:interface:axis_rtl:1.0" \
  "xilinx.com:interface:axis:1.0" \
  {
    {"s_axis_valid" "TVALID"} \
    {"s_axis_ready" "TREADY"} \
    {"s_axis_data" "TDATA"} \
  }

foreach bus {m_axis_tx m_axis_conjugate} {
  adi_add_bus $bus "master" \
    "xilinx.com:interface:axis_rtl:1.0" \
    "xilinx.com:interface:axis:1.0" \
    [list \
      [list "${bus}_valid" "TVALID"] \
      [list "${bus}_ready" "TREADY"] \
      [list "${bus}_data" "TDATA"]]
}

set cc [ipx::current_core]
set tx_dependency {spirit:decode(id('MODELPARAM_VALUE.ENABLE_M_AXIS_TX')) = 1}
adi_set_bus_dependency m_axis_tx m_axis_tx $tx_dependency
foreach param [list \
  [ipx::get_user_parameters ENABLE_M_AXIS_TX -of_objects $cc] \
  [ipx::get_hdl_parameters ENABLE_M_AXIS_TX -of_objects $cc]] {
  set_property -dict [list value_format bool value true] $param
}
set_property DISPLAY_NAME {Enable m_axis_tx} \
  [ipgui::get_guiparamspec -name ENABLE_M_AXIS_TX -component $cc]

adi_add_bus_clock "clk" "s_axis:m_axis_tx:m_axis_conjugate" "reset"
ipx::save_core [ipx::current_core]
