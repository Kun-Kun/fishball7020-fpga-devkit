// ***************************************************************************
// Copyright (C) 2026 Fishball
// SPDX-License-Identifier: BSD-1-Clause
// ***************************************************************************

`timescale 1ns/100ps

// AXI4-Stream delay with one elastic register per clock of latency.
// With an always-ready sink, each accepted beat appears after DELAY_CYCLES
// rising edges. Backpressure can extend that latency without losing beats.
module axis_delay #(
  parameter integer DELAY_CYCLES = 1,
  parameter integer DATA_WIDTH = 32,
  parameter integer KEEP_WIDTH = (DATA_WIDTH + 7) / 8,
  parameter integer USER_WIDTH = 1,
  parameter integer ID_WIDTH = 1,
  parameter integer DEST_WIDTH = 1,
  parameter integer ENABLE_SIDEBANDS = 1
) (
  input                         clk,
  input                         reset,

  input                         s_axis_tvalid,
  output                        s_axis_tready,
  input      [DATA_WIDTH-1:0]    s_axis_tdata,
  input      [KEEP_WIDTH-1:0]    s_axis_tkeep,
  input      [KEEP_WIDTH-1:0]    s_axis_tstrb,
  input                         s_axis_tlast,
  input      [USER_WIDTH-1:0]    s_axis_tuser,
  input      [ID_WIDTH-1:0]      s_axis_tid,
  input      [DEST_WIDTH-1:0]    s_axis_tdest,

  output                        m_axis_tvalid,
  input                         m_axis_tready,
  output     [DATA_WIDTH-1:0]    m_axis_tdata,
  output     [KEEP_WIDTH-1:0]    m_axis_tkeep,
  output     [KEEP_WIDTH-1:0]    m_axis_tstrb,
  output                        m_axis_tlast,
  output     [USER_WIDTH-1:0]    m_axis_tuser,
  output     [ID_WIDTH-1:0]      m_axis_tid,
  output     [DEST_WIDTH-1:0]    m_axis_tdest
);

  localparam integer PAYLOAD_WIDTH = DATA_WIDTH + 2*KEEP_WIDTH +
                                     USER_WIDTH + ID_WIDTH + DEST_WIDTH + 1;
  wire [PAYLOAD_WIDTH-1:0] input_payload;
  wire [PAYLOAD_WIDTH-1:0] output_payload;

  // A data-only stream can omit storage for AXI sidebands that its producer
  // and consumer do not use. The output then carries ordinary defaults.
  assign input_payload = ENABLE_SIDEBANDS ?
                         {s_axis_tdata, s_axis_tkeep, s_axis_tstrb,
                          s_axis_tlast, s_axis_tuser, s_axis_tid,
                          s_axis_tdest} :
                         {s_axis_tdata, {KEEP_WIDTH{1'b1}},
                          {KEEP_WIDTH{1'b1}}, 1'b0, {USER_WIDTH{1'b0}},
                          {ID_WIDTH{1'b0}}, {DEST_WIDTH{1'b0}}};
  assign {m_axis_tdata, m_axis_tkeep, m_axis_tstrb, m_axis_tlast,
          m_axis_tuser, m_axis_tid, m_axis_tdest} = output_payload;

  generate if (DELAY_CYCLES == 0) begin : bypass
    assign s_axis_tready = ~reset & m_axis_tready;
    assign m_axis_tvalid = ~reset & s_axis_tvalid;
    assign output_payload = input_payload;
  end else begin : delay
    reg  [DELAY_CYCLES-1:0] valid;
    reg  [PAYLOAD_WIDTH-1:0] payload [0:DELAY_CYCLES-1];
    wire [DELAY_CYCLES:0] ready;
    genvar i;

    assign ready[DELAY_CYCLES] = m_axis_tready;
    assign s_axis_tready = ~reset & ready[0];
    assign m_axis_tvalid = ~reset & valid[DELAY_CYCLES-1];
    assign output_payload = payload[DELAY_CYCLES-1];

    for (i = 0; i < DELAY_CYCLES; i = i + 1) begin : stage
      assign ready[i] = ~valid[i] | ready[i+1];

      always @(posedge clk) begin
        if (reset) begin
          valid[i] <= 1'b0;
        end else if (ready[i]) begin
          if (i == 0) begin
            valid[i] <= s_axis_tvalid;
            if (s_axis_tvalid)
              payload[i] <= input_payload;
          end else begin
            valid[i] <= valid[i-1];
            if (valid[i-1])
              payload[i] <= payload[i-1];
          end
        end
      end
    end
  end endgenerate

endmodule
