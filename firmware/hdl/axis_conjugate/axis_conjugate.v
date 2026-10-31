// ***************************************************************************
// Copyright (C) 2026 Fishball
// SPDX-License-Identifier: BSD-1-Clause
// ***************************************************************************

`timescale 1ns/100ps

// Conjugate a complex AXIS stream. Optionally forward the unchanged samples
// to a second consumer, with each output beat delivered exactly once.
module axis_conjugate #(
  parameter ENABLE_M_AXIS_TX = 1
) (
  input             clk,
  input             reset,

  input             s_axis_valid,
  output            s_axis_ready,
  input      [31:0] s_axis_data,

  output            m_axis_tx_valid,
  input             m_axis_tx_ready,
  output     [31:0] m_axis_tx_data,

  output            m_axis_conjugate_valid,
  input             m_axis_conjugate_ready,
  output     [31:0] m_axis_conjugate_data
);

  reg        conjugate_valid_reg;
  reg        tx_valid_reg;
  reg [31:0] data_reg;
  wire [15:0] conjugate_q;

  // Saturate the Q1.15 -1.0 endpoint: its positive conjugate cannot be
  // represented in a signed 16-bit fraction.
  assign conjugate_q = (data_reg[31:16] == 16'h8000) ?
                       16'h7fff : (~data_reg[31:16] + 1'b1);

  // One elastic sample register isolates upstream logic from the Q-negation
  // carry chain. Track each consumer separately so a stalled output cannot
  // make the other output receive the same sample twice.
  assign s_axis_ready = (~conjugate_valid_reg | m_axis_conjugate_ready) &
                        (!ENABLE_M_AXIS_TX | ~tx_valid_reg | m_axis_tx_ready);
  assign m_axis_tx_valid = ENABLE_M_AXIS_TX ? tx_valid_reg : 1'b0;
  assign m_axis_tx_data = ENABLE_M_AXIS_TX ? data_reg : 32'b0;
  assign m_axis_conjugate_valid = conjugate_valid_reg;
  assign m_axis_conjugate_data = {conjugate_q, data_reg[15:0]};

  always @(posedge clk) begin
    if (reset) begin
      conjugate_valid_reg <= 1'b0;
      tx_valid_reg <= 1'b0;
      data_reg <= 32'b0;
    end else if (s_axis_ready) begin
      conjugate_valid_reg <= s_axis_valid;
      tx_valid_reg <= ENABLE_M_AXIS_TX && s_axis_valid;
      if (s_axis_valid)
        data_reg <= s_axis_data;
    end else begin
      if (conjugate_valid_reg && m_axis_conjugate_ready)
        conjugate_valid_reg <= 1'b0;
      if (tx_valid_reg && m_axis_tx_ready)
        tx_valid_reg <= 1'b0;
    end
  end

endmodule
