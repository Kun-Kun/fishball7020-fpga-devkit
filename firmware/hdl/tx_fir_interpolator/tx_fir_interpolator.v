// ***************************************************************************
// Local two-channel complex AXI-stream transmit interpolator.
// SPDX short identifier: BSD-1-Clause
// ***************************************************************************

`timescale 1ns/100ps

module tx_fir_interpolator (
  input aclk,
  input reset,
  input active,
  input select_axis,
  output select_axis_sync,

  input  [31:0] s_axis_0_tdata,
  input         s_axis_0_tvalid,
  output        s_axis_0_tready,
  output [31:0] m_axis_0_tdata,
  output        m_axis_0_tvalid,
  input         m_axis_0_tready,

  input  [31:0] s_axis_1_tdata,
  input         s_axis_1_tvalid,
  output        s_axis_1_tready,
  output [31:0] m_axis_1_tdata,
  output        m_axis_1_tvalid,
  input         m_axis_1_tready
);

  wire active_sync;

  sync_bits active_sync_inst (
    .in_bits(active),
    .out_resetn(~reset),
    .out_clk(aclk),
    .out_bits(active_sync)
  );

  sync_bits select_axis_sync_inst (
    .in_bits(select_axis),
    .out_resetn(~reset),
    .out_clk(aclk),
    .out_bits(select_axis_sync)
  );

  tx_fir_interpolator_channel channel_0 (
    .aclk(aclk), .active(active_sync),
    .s_axis_tdata(s_axis_0_tdata), .s_axis_tvalid(s_axis_0_tvalid),
    .s_axis_tready(s_axis_0_tready),
    .m_axis_tdata(m_axis_0_tdata), .m_axis_tvalid(m_axis_0_tvalid),
    .m_axis_tready(m_axis_0_tready)
  );

  tx_fir_interpolator_channel channel_1 (
    .aclk(aclk), .active(active_sync),
    .s_axis_tdata(s_axis_1_tdata), .s_axis_tvalid(s_axis_1_tvalid),
    .s_axis_tready(s_axis_1_tready),
    .m_axis_tdata(m_axis_1_tdata), .m_axis_tvalid(m_axis_1_tvalid),
    .m_axis_tready(m_axis_1_tready)
  );

endmodule

module tx_fir_interpolator_channel (
  input aclk,
  input active,
  input  [31:0] s_axis_tdata,
  input         s_axis_tvalid,
  output        s_axis_tready,
  output [31:0] m_axis_tdata,
  output        m_axis_tvalid,
  input         m_axis_tready
);

  wire [15:0] fir_i_data;
  wire [15:0] fir_q_data;
  wire fir_i_valid;
  wire fir_q_valid;
  wire fir_i_ready;
  wire fir_q_ready;
  wire fir_i_out_ready;
  wire fir_q_out_ready;

  // The I and Q filters accept and retire each complex beat together.
  assign s_axis_tready = active ? (fir_i_ready & fir_q_ready) : m_axis_tready;
  assign m_axis_tvalid = active ? (fir_i_valid & fir_q_valid) : s_axis_tvalid;
  assign m_axis_tdata = active ? {fir_q_data, fir_i_data} : s_axis_tdata;
  assign fir_i_out_ready = active & m_axis_tready & fir_q_valid;
  assign fir_q_out_ready = active & m_axis_tready & fir_i_valid;

  fir_interpolator fir_i (
    .aclk(aclk),
    .s_axis_data_tvalid(s_axis_tvalid & active),
    .s_axis_data_tready(fir_i_ready),
    .s_axis_data_tdata(s_axis_tdata[15:0]),
    .m_axis_data_tvalid(fir_i_valid),
    .m_axis_data_tready(fir_i_out_ready),
    .m_axis_data_tdata(fir_i_data)
  );

  fir_interpolator fir_q (
    .aclk(aclk),
    .s_axis_data_tvalid(s_axis_tvalid & active),
    .s_axis_data_tready(fir_q_ready),
    .s_axis_data_tdata(s_axis_tdata[31:16]),
    .m_axis_data_tvalid(fir_q_valid),
    .m_axis_data_tready(fir_q_out_ready),
    .m_axis_data_tdata(fir_q_data)
  );

endmodule
