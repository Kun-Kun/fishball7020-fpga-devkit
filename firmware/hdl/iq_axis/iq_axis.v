// ***************************************************************************
// Copyright (C) 2026 Fishball
// SPDX-License-Identifier: BSD-1-Clause
// ***************************************************************************

`timescale 1ns/100ps

// Convert one parallel I/Q receive channel into a 32-bit AXI4-Stream source.
// TDATA[15:0] is I and TDATA[31:16] is Q.  The RF sample source has no
// backpressure, therefore this module has one elastic register and reports a
// rejected sample on overflow.
module iq_axis (
  input             clk,
  input             reset,

  input             enable_i,
  input             enable_q,
  input             valid_i,
  input             valid_q,
  input      [15:0] data_i,
  input      [15:0] data_q,
  output            ready,
  output reg        overflow,

  output reg        m_axis_valid,
  input             m_axis_ready,
  output reg [31:0] m_axis_data
);

  wire sample_valid;

  assign sample_valid = enable_i & enable_q & valid_i & valid_q;
  assign ready = ~m_axis_valid | m_axis_ready;

  always @(posedge clk) begin
    if (reset == 1'b1) begin
      m_axis_valid <= 1'b0;
      m_axis_data <= 32'b0;
      overflow <= 1'b0;
    end else begin
      overflow <= sample_valid & ~ready;
      if (ready) begin
        m_axis_valid <= sample_valid;
        if (sample_valid) begin
          m_axis_data <= {data_q, data_i};
        end
      end
    end
  end

endmodule
