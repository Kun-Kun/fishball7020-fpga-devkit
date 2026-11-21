// Copyright (C) 2026 Fishball
// SPDX-License-Identifier: BSD-1-Clause
`timescale 1ns/100ps

// Four-word AXIS FIFO with registered occupancy. Input ready is independent
// of output ready, breaking the cpack cross-channel combinational ready path.
module axis_fifo4 (
  input clk, reset,
  input [31:0] s_axis_tdata,
  input s_axis_tvalid,
  output s_axis_tready,
  output [31:0] m_axis_tdata,
  output m_axis_tvalid,
  input m_axis_tready
);
  reg [31:0] words [0:3];
  reg [1:0] read_ptr = 0, write_ptr = 0;
  reg [2:0] count = 0;
  wire push = s_axis_tvalid && s_axis_tready;
  wire pop = m_axis_tvalid && m_axis_tready;
  assign s_axis_tready = !reset && count < 4;
  assign m_axis_tvalid = !reset && count != 0;
  assign m_axis_tdata = words[read_ptr];
  always @(posedge clk) begin
    if (reset) begin
      read_ptr <= 0;
      write_ptr <= 0;
      count <= 0;
    end else begin
      if (push) begin
        words[write_ptr] <= s_axis_tdata;
        write_ptr <= write_ptr + 1'b1;
      end
      if (pop) read_ptr <= read_ptr + 1'b1;
      case ({push, pop})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: count <= count;
      endcase
    end
  end
endmodule
