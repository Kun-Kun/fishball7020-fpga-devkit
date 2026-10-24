// One complex AXI4-Stream channel with an interpolator bypass.
// SPDX-License-Identifier: BSD-1-Clause

`timescale 1ns/100ps

module tx_fir_interpolator (
  input aclk,
  input reset,
  input active,

  input  [31:0] s_axis_tdata,
  input         s_axis_tvalid,
  output        s_axis_tready,
  output [31:0] m_axis_tdata,
  output        m_axis_tvalid,
  input         m_axis_tready
);

  wire active_sync;
  sync_bits active_sync_inst (
    .in_bits(active), .out_resetn(~reset), .out_clk(aclk),
    .out_bits(active_sync)
  );

  wire [15:0] fir_i_data;
  wire [15:0] fir_q_data;
  wire fir_i_valid;
  wire fir_q_valid;
  wire fir_i_ready;
  wire fir_q_ready;
  wire fir_i_out_ready;
  wire fir_q_out_ready;
  wire fir_i_in_valid;
  wire fir_q_in_valid;
  wire fir_i_in_fire;
  wire fir_q_in_fire;

  reg        input_valid;
  reg [31:0] input_data;
  reg        input_i_pending;
  reg        input_q_pending;

  // Hold one complex input beat until both independent FIR input interfaces
  // have accepted it. TVALID cannot be broadcast directly: one FIR may accept
  // the same held beat more than once while the other FIR is back-pressuring.
  assign s_axis_tready = active_sync ? ~input_valid : m_axis_tready;
  assign fir_i_in_valid = active_sync & input_valid & input_i_pending;
  assign fir_q_in_valid = active_sync & input_valid & input_q_pending;
  assign fir_i_in_fire = fir_i_in_valid & fir_i_ready;
  assign fir_q_in_fire = fir_q_in_valid & fir_q_ready;

  always @(posedge aclk) begin
    if (reset) begin
      input_valid <= 1'b0;
      input_data <= 32'b0;
      input_i_pending <= 1'b0;
      input_q_pending <= 1'b0;
    end else if (!active_sync) begin
      input_valid <= 1'b0;
      input_i_pending <= 1'b0;
      input_q_pending <= 1'b0;
    end else if (!input_valid) begin
      if (s_axis_tvalid) begin
        input_valid <= 1'b1;
        input_data <= s_axis_tdata;
        input_i_pending <= 1'b1;
        input_q_pending <= 1'b1;
      end
    end else begin
      if (fir_i_in_fire)
        input_i_pending <= 1'b0;
      if (fir_q_in_fire)
        input_q_pending <= 1'b0;
      if ((!input_i_pending || fir_i_in_fire) &&
          (!input_q_pending || fir_q_in_fire)) begin
        input_valid <= 1'b0;
        input_i_pending <= 1'b0;
        input_q_pending <= 1'b0;
      end
    end
  end

  assign m_axis_tvalid = active_sync ? (fir_i_valid & fir_q_valid) : s_axis_tvalid;
  assign m_axis_tdata = active_sync ? {fir_q_data, fir_i_data} : s_axis_tdata;
  assign fir_i_out_ready = active_sync & m_axis_tready & fir_q_valid;
  assign fir_q_out_ready = active_sync & m_axis_tready & fir_i_valid;

  fir_interpolator fir_i (
    .aclk(aclk),
    .s_axis_data_tvalid(fir_i_in_valid),
    .s_axis_data_tready(fir_i_ready),
    .s_axis_data_tdata(input_data[15:0]),
    .m_axis_data_tvalid(fir_i_valid),
    .m_axis_data_tready(fir_i_out_ready),
    .m_axis_data_tdata(fir_i_data)
  );

  fir_interpolator fir_q (
    .aclk(aclk),
    .s_axis_data_tvalid(fir_q_in_valid),
    .s_axis_data_tready(fir_q_ready),
    .s_axis_data_tdata(input_data[31:16]),
    .m_axis_data_tvalid(fir_q_valid),
    .m_axis_data_tready(fir_q_out_ready),
    .m_axis_data_tdata(fir_q_data)
  );

endmodule
