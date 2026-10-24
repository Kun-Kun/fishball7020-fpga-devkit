# ***************************************************************************
# Copyright (C) 2026 Fishball
# SPDX-License-Identifier: BSD-1-Clause
# ***************************************************************************

source ../../scripts/adi_env.tcl
source $ad_hdl_dir/library/scripts/adi_ip_xilinx.tcl

adi_ip_create axis_iq
adi_ip_files axis_iq [list "axis_iq.v"]
adi_ip_properties_lite axis_iq

adi_add_bus "s_axis" "slave" \
  "xilinx.com:interface:axis_rtl:1.0" \
  "xilinx.com:interface:axis:1.0" \
  {
    {"s_axis_valid" "TVALID"} \
    {"s_axis_ready" "TREADY"} \
    {"s_axis_data" "TDATA"} \
  }

adi_add_bus_clock "clk" "s_axis" "reset"
ipx::save_core [ipx::current_core]
