# ***************************************************************************
# Copyright (C) 2026 Fishball
# SPDX-License-Identifier: BSD-1-Clause
# ***************************************************************************

source ../../scripts/adi_env.tcl
source $ad_hdl_dir/library/scripts/adi_ip_xilinx.tcl

adi_ip_create iq_axis
adi_ip_files iq_axis [list "iq_axis.v"]
adi_ip_properties_lite iq_axis

adi_add_bus "m_axis" "master" \
  "xilinx.com:interface:axis_rtl:1.0" \
  "xilinx.com:interface:axis:1.0" \
  {
    {"m_axis_valid" "TVALID"} \
    {"m_axis_ready" "TREADY"} \
    {"m_axis_data" "TDATA"} \
  }

adi_add_bus_clock "clk" "m_axis" "reset"
ipx::save_core [ipx::current_core]
