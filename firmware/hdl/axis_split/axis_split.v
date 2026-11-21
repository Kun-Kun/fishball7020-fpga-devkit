// Copyright (C) 2026 Fishball
// SPDX-License-Identifier: BSD-1-Clause
`timescale 1ns/100ps

// Deliver every selected TX reference sample to both RX multipliers exactly
// once, including when either multiplier stalls independently.
module axis_split (
  input clk, reset,
  input [31:0] s_axis_tdata,
  input s_axis_tvalid,
  output s_axis_tready,
  output [31:0] m_axis_0_tdata,
  output m_axis_0_tvalid,
  input m_axis_0_tready,
  output [31:0] m_axis_1_tdata,
  output m_axis_1_tvalid,
  input m_axis_1_tready
);
  reg [31:0] data_reg = 0;
  reg valid0 = 0, valid1 = 0;
  assign s_axis_tready = !reset && (!valid0 || m_axis_0_tready) &&
                         (!valid1 || m_axis_1_tready);
  assign m_axis_0_tdata = data_reg;
  assign m_axis_1_tdata = data_reg;
  assign m_axis_0_tvalid = !reset && valid0;
  assign m_axis_1_tvalid = !reset && valid1;
  always @(posedge clk) begin
    if (reset) begin
      valid0 <= 0;
      valid1 <= 0;
    end else if (s_axis_tready) begin
      valid0 <= s_axis_tvalid;
      valid1 <= s_axis_tvalid;
      if (s_axis_tvalid) data_reg <= s_axis_tdata;
    end else begin
      if (valid0 && m_axis_0_tready) valid0 <= 0;
      if (valid1 && m_axis_1_tready) valid1 <= 0;
    end
  end
endmodule
