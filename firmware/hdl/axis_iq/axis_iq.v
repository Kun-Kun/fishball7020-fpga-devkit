// ***************************************************************************
// Copyright (C) 2026 Fishball
// SPDX-License-Identifier: BSD-1-Clause
// ***************************************************************************

`timescale 1ns/100ps

// Convert one 32-bit AXI4-Stream sink into a parallel I/Q transmit channel.
// TDATA[15:0] is I and TDATA[31:16] is Q.  One prefetched beat is retained so
// that a synchronous RF request sees data accepted before its request cycle.
module axis_iq (
  input             clk,
  input             reset,

  input             s_axis_valid,
  output            s_axis_ready,
  input      [31:0] s_axis_data,

  input             enable_i,
  input             enable_q,
  input             request_i,
  input             request_q,
  output reg        valid_i,
  output reg        valid_q,
  output reg [15:0] data_i,
  output reg [15:0] data_q,
  output reg        underflow
);

  wire sample_request;
  wire pop;
  wire push;
  reg        buffer_valid;
  reg [31:0] buffer_data;

  assign sample_request = enable_i & enable_q & request_i & request_q;
  assign pop = sample_request & buffer_valid;
  assign s_axis_ready = ~buffer_valid | sample_request;
  assign push = s_axis_valid & s_axis_ready;

  always @(posedge clk) begin
    if (reset == 1'b1) begin
      buffer_valid <= 1'b0;
      buffer_data <= 32'b0;
      data_i <= 16'b0;
      data_q <= 16'b0;
      valid_i <= 1'b0;
      valid_q <= 1'b0;
      underflow <= 1'b0;
    end else begin
      valid_i <= pop;
      valid_q <= pop;
      underflow <= sample_request & ~buffer_valid;

      if (pop) begin
        data_i <= buffer_data[15:0];
        data_q <= buffer_data[31:16];
      end else if (sample_request) begin
        data_i <= 16'b0;
        data_q <= 16'b0;
      end

      case ({push, pop})
        2'b10: begin
          buffer_data <= s_axis_data;
          buffer_valid <= 1'b1;
        end
        2'b01: buffer_valid <= 1'b0;
        2'b11: begin
          buffer_data <= s_axis_data;
          buffer_valid <= 1'b1;
        end
        default: buffer_valid <= buffer_valid;
      endcase
    end
  end

endmodule
