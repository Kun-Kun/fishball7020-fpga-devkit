// ***************************************************************************
// Copyright (C) 2026 Fishball
// SPDX-License-Identifier: BSD-1-Clause
// ***************************************************************************

`timescale 1ns/100ps

// Pass AXI samples between a rising START and a rising STOP. Samples arriving
// while closed are accepted and discarded, so a non-stallable ADC can keep
// running without filling an upstream register. STOP may be a short,
// asynchronous MUXOUT pulse: its asynchronous-set latch holds it until the
// stream clock has observed it. DONE stays high until the next START or reset.
module axis_gate #(
  parameter integer DATA_WIDTH = 32
) (
  input                       clk,
  input                       reset,
  input                       start,
  input                       stop,
  input                       abort,
  input                       bypass,
  output reg                  active,
  output reg                  done,

  input                       s_axis_tvalid,
  output                      s_axis_tready,
  input      [DATA_WIDTH-1:0]  s_axis_tdata,
  output                      m_axis_tvalid,
  input                       m_axis_tready,
  output reg [DATA_WIDTH-1:0]  m_axis_tdata
);

  (* ASYNC_REG = "TRUE" *) reg start_meta, start_sync;
  reg start_prev;
  reg stop_pending;
  (* ASYNC_REG = "TRUE" *) reg stop_meta, stop_sync;
  reg stop_prev;
  reg output_valid;

  wire start_edge = start_sync & ~start_prev;
  wire stop_edge = stop_sync & ~stop_prev;
  wire forwarding = bypass | (active & ~stop_edge & ~abort);

  // MUXOUT's ramp-complete pulse may be shorter than one stream clock. A
  // flip-flop with asynchronous set captures it; the synchronized level
  // acknowledges and clears it after the event has reached this domain.
  always @(posedge clk or posedge stop) begin
    if (stop)
      stop_pending <= 1'b1;
    else if (reset || stop_sync)
      stop_pending <= 1'b0;
  end

  assign s_axis_tready = reset ? 1'b0 :
                         forwarding ? (~output_valid | m_axis_tready) : 1'b1;
  assign m_axis_tvalid = ~reset & output_valid;

  always @(posedge clk) begin
    if (reset) begin
      start_meta <= 1'b0;
      start_sync <= 1'b0;
      start_prev <= 1'b0;
      stop_meta <= 1'b0;
      stop_sync <= 1'b0;
      stop_prev <= 1'b0;
      active <= 1'b0;
      done <= 1'b0;
      output_valid <= 1'b0;
      m_axis_tdata <= {DATA_WIDTH{1'b0}};
    end else begin
      start_meta <= start;
      start_sync <= start_meta;
      start_prev <= start_sync;
      stop_meta <= stop_pending;
      stop_sync <= stop_meta;
      stop_prev <= stop_sync;

      if (abort) begin
        active <= 1'b0;
        done <= 1'b0;
      end else if (stop_edge && active) begin
        active <= 1'b0;
        done <= 1'b1;
      end else if (start_edge) begin
        active <= 1'b1;
        done <= 1'b0;
      end

      if (~output_valid | m_axis_tready) begin
        output_valid <= ~abort & forwarding & s_axis_tvalid;
        if (forwarding & s_axis_tvalid)
          m_axis_tdata <= s_axis_tdata;
      end
    end
  end
endmodule
