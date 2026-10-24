// ***************************************************************************
// ***************************************************************************
// Copyright (C) 2014-2023 Analog Devices, Inc. All rights reserved.
//
// This core is distributed under the GNU General Public License version 2 or
// the ADI specific BSD license. See LICENSE_GPL2 and LICENSE_ADIBSD in the
// HDL repository for details.
// ***************************************************************************
// ***************************************************************************

`timescale 1ns/100ps

// AXI4-Stream equivalent of ad_bus_mux for a decimator's filtered/bypass
// paths. select_path=0 forwards S_AXIS unchanged. select_path=1 sends S_AXIS
// to the FIR and forwards the FIR result. Ready follows the selected path.
module ad_axis_mux (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK",
     X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXIS:M_AXIS_TO_FIR:S_AXIS_FROM_FIR:M_AXIS, FREQ_HZ 100000000" *)
  input                  aclk,
  input                  select_path,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
  input      [31:0]      s_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID",
     X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS, TDATA_NUM_BYTES 4, HAS_TREADY 1, HAS_TLAST 0" *)
  input                  s_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
  output                 s_axis_tready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TO_FIR TDATA" *)
  output     [31:0]      m_axis_to_fir_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TO_FIR TVALID",
     X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS_TO_FIR, TDATA_NUM_BYTES 4, HAS_TREADY 1, HAS_TLAST 0" *)
  output                 m_axis_to_fir_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_TO_FIR TREADY" *)
  input                  m_axis_to_fir_tready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_FROM_FIR TDATA" *)
  input      [31:0]      s_axis_from_fir_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_FROM_FIR TVALID",
     X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS_FROM_FIR, TDATA_NUM_BYTES 4, HAS_TREADY 1, HAS_TLAST 0" *)
  input                  s_axis_from_fir_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_FROM_FIR TREADY" *)
  output                 s_axis_from_fir_tready,

  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
  output     [31:0]      m_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID",
     X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS, TDATA_NUM_BYTES 4, HAS_TREADY 1, HAS_TLAST 0" *)
  output                 m_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
  input                  m_axis_tready,

  output     [31:0]      data_out,
  output                 valid_out
);

  assign m_axis_to_fir_tdata = s_axis_tdata;
  assign m_axis_to_fir_tvalid = s_axis_tvalid & select_path;
  assign s_axis_tready = select_path ? m_axis_to_fir_tready : m_axis_tready;

  assign m_axis_tdata = select_path ? s_axis_from_fir_tdata : s_axis_tdata;
  assign m_axis_tvalid = select_path ? s_axis_from_fir_tvalid : s_axis_tvalid;
  assign s_axis_from_fir_tready = select_path & m_axis_tready;
  assign data_out = m_axis_tdata;
  assign valid_out = m_axis_tvalid;

endmodule
