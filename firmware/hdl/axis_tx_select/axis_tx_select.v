// Copyright (C) 2026 Fishball
// SPDX-License-Identifier: BSD-1-Clause
`timescale 1ns/100ps

// Preserve each TX stream and tap the selected one for the shared RX beat
// reference. Change select_tx2 only while TX DMA is stopped; switching flushes
// pending samples so a new capture cannot use the previous TX reference.
module axis_tx_select (
  input clk, reset, select_tx2,
  input [31:0] s_axis_tx1_tdata,
  input s_axis_tx1_tvalid,
  output s_axis_tx1_tready,
  input [31:0] s_axis_tx2_tdata,
  input s_axis_tx2_tvalid,
  output s_axis_tx2_tready,
  output [31:0] m_axis_tx1_tdata,
  output m_axis_tx1_tvalid,
  input m_axis_tx1_tready,
  output [31:0] m_axis_tx2_tdata,
  output m_axis_tx2_tvalid,
  input m_axis_tx2_tready,
  output [31:0] m_axis_ref_tdata,
  output m_axis_ref_tvalid,
  input m_axis_ref_tready
);
  (* ASYNC_REG = "TRUE" *) reg select_meta = 0, select_sync = 0;
  reg select_prev = 0;
  wire switching = select_sync != select_prev;
  reg [31:0] tx1_data = 0, tx2_data = 0;
  reg tx1_valid = 0, tx2_valid = 0, ref1_valid = 0, ref2_valid = 0;

  assign m_axis_tx1_tdata = tx1_data;
  assign m_axis_tx2_tdata = tx2_data;
  assign m_axis_ref_tdata = select_sync ? tx2_data : tx1_data;
  assign m_axis_tx1_tvalid = !reset && !switching && tx1_valid;
  assign m_axis_tx2_tvalid = !reset && !switching && tx2_valid;
  assign m_axis_ref_tvalid = !reset && !switching &&
                             (select_sync ? ref2_valid : ref1_valid);
  assign s_axis_tx1_tready = !reset && !switching &&
      (!tx1_valid || m_axis_tx1_tready) &&
      (select_sync || !ref1_valid || m_axis_ref_tready);
  assign s_axis_tx2_tready = !reset && !switching &&
      (!tx2_valid || m_axis_tx2_tready) &&
      (!select_sync || !ref2_valid || m_axis_ref_tready);

  always @(posedge clk) begin
    if (reset) begin
      select_meta <= 0;
      select_sync <= 0;
      select_prev <= 0;
      tx1_valid <= 0;
      tx2_valid <= 0;
      ref1_valid <= 0;
      ref2_valid <= 0;
    end else begin
      select_meta <= select_tx2;
      select_sync <= select_meta;
      select_prev <= select_sync;
      if (switching) begin
        tx1_valid <= 0;
        tx2_valid <= 0;
        ref1_valid <= 0;
        ref2_valid <= 0;
      end else begin
        if (s_axis_tx1_tready) begin
          tx1_valid <= s_axis_tx1_tvalid;
          ref1_valid <= s_axis_tx1_tvalid && !select_sync;
          if (s_axis_tx1_tvalid) tx1_data <= s_axis_tx1_tdata;
        end else begin
          if (tx1_valid && m_axis_tx1_tready) tx1_valid <= 0;
          if (ref1_valid && m_axis_ref_tready && !select_sync) ref1_valid <= 0;
        end
        if (s_axis_tx2_tready) begin
          tx2_valid <= s_axis_tx2_tvalid;
          ref2_valid <= s_axis_tx2_tvalid && select_sync;
          if (s_axis_tx2_tvalid) tx2_data <= s_axis_tx2_tdata;
        end else begin
          if (tx2_valid && m_axis_tx2_tready) tx2_valid <= 0;
          if (ref2_valid && m_axis_ref_tready && select_sync) ref2_valid <= 0;
        end
      end
    end
  end
endmodule
