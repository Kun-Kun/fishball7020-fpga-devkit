// Copyright (C) 2026 Fishball
// SPDX-License-Identifier: BSD-1-Clause
`timescale 1ns/100ps

// Frame a gated, FIR-processed complex stream for an unpacketized IIO DMA.
// Zero idle words keep DMA refills moving after the finite ramp. Payload
// occurrences of MAGIC and ESC are escaped, so headers are unambiguous.
module axis_frame (
  input clk, reset, start, stop, abort, bypass,
  input s_axis_tvalid,
  output s_axis_tready,
  input [31:0] s_axis_tdata,
  output m_axis_tvalid,
  input m_axis_tready,
  output [31:0] m_axis_tdata
);
  localparam [31:0] MAGIC = 32'hf15acafe, ESC = 32'hf15acafd;
  localparam [31:0] START = 32'h53544152, END = 32'h454e4421;
  localparam IDLE=0, START_MAGIC=1, START_TAG=2, START_SEQ=3,
             DATA=4, LITERAL=5, END_MAGIC=6, END_TAG=7,
             END_SEQ=8, END_COUNT=9, END_XOR=10;
  reg [3:0] state = IDLE;
  reg [31:0] seq_num = 0, count = 0, checksum = 0;
  reg input_valid = 0;
  reg [31:0] input_data = 0;
  reg [8:0] quiet = 0;
  reg [6:0] idle_div = 0;
  reg stopping = 0;
  (* ASYNC_REG = "TRUE" *) reg start_meta=0, start_sync=0;
  reg start_prev=0;
  reg stop_latched=0;
  (* ASYNC_REG = "TRUE" *) reg stop_meta=0, stop_sync=0;
  reg stop_prev=0;
  wire start_edge = start_sync & ~start_prev;
  wire stop_edge = stop_sync & ~stop_prev;
  wire reserved_word = input_data == MAGIC || input_data == ESC;
  reg output_valid = 0;
  reg [31:0] output_data = 0;
  reg bypass_prev = 0;
  wire output_ready = ~output_valid | m_axis_tready;
  wire emit_valid = bypass ? s_axis_tvalid :
      state == IDLE ? (idle_div == 0) :
      state == DATA ? input_valid : 1'b1;
  wire [31:0] emit_data = bypass ? s_axis_tdata :
      state == IDLE ? 32'b0 :
      state == START_MAGIC || state == END_MAGIC ? MAGIC :
      state == START_TAG ? START : state == END_TAG ? END :
      state == START_SEQ || state == END_SEQ ? seq_num :
      state == END_COUNT ? count : state == END_XOR ? checksum :
      state == DATA && reserved_word ? ESC : input_data;

  // Catch MUXOUT even when narrower than one stream clock.
  always @(posedge clk or posedge stop) begin
    if (stop) stop_latched <= 1'b1;
    else if (reset || stop_sync) stop_latched <= 1'b0;
  end

  assign s_axis_tready = ~reset & (bypass ? output_ready :
      state == DATA && !input_valid);
  assign m_axis_tvalid = output_valid;
  assign m_axis_tdata = output_data;

  always @(posedge clk) begin
    if (reset) begin
      state <= IDLE;
      seq_num <= 0;
      count <= 0;
      checksum <= 0;
      input_valid <= 0;
      input_data <= 0;
      quiet <= 0;
      idle_div <= 0;
      stopping <= 0;
      start_meta <= 0; start_sync <= 0; start_prev <= 0;
      stop_meta <= 0; stop_sync <= 0; stop_prev <= 0;
      output_valid <= 0;
      output_data <= 0;
      bypass_prev <= 0;
    end else begin
      start_meta <= start; start_sync <= start_meta; start_prev <= start_sync;
      stop_meta <= stop_latched; stop_sync <= stop_meta; stop_prev <= stop_sync;
      idle_div <= idle_div + 1'b1;
      bypass_prev <= bypass;
      if (bypass != bypass_prev) output_valid <= 0;
      else if (output_ready) begin
        output_valid <= emit_valid;
        if (emit_valid) output_data <= emit_data;
      end
      if (bypass || abort) begin
        state <= IDLE;
        stopping <= 0;
        input_valid <= 0;
      end else begin
        if (stop_edge) stopping <= 1;
        if (state == IDLE && start_edge) begin
          state <= START_MAGIC;
          seq_num <= seq_num + 1'b1;
          count <= 0;
          checksum <= 0;
          input_valid <= 0;
          quiet <= 0;
          stopping <= 0;
        end else if (state == DATA) begin
          if (s_axis_tvalid && s_axis_tready) begin
            input_data <= s_axis_tdata;
            input_valid <= 1;
          end
          if (s_axis_tvalid || input_valid) quiet <= 0;
          else if (stopping && quiet != 9'd511) quiet <= quiet + 1'b1;
          if (stopping && quiet == 9'd511 && !s_axis_tvalid && !input_valid)
            state <= END_MAGIC;
          else if (input_valid && output_ready) begin
            if (reserved_word) state <= LITERAL;
            else begin
              input_valid <= 0;
              count <= count + 1'b1;
              checksum <= checksum ^ input_data;
            end
          end
        end else if (output_ready) begin
          case (state)
            START_MAGIC: state <= START_TAG;
            START_TAG: state <= START_SEQ;
            START_SEQ: state <= DATA;
            LITERAL: begin
              state <= DATA;
              input_valid <= 0;
              count <= count + 1'b1;
              checksum <= checksum ^ input_data;
            end
            END_MAGIC: state <= END_TAG;
            END_TAG: state <= END_SEQ;
            END_SEQ: state <= END_COUNT;
            END_COUNT: state <= END_XOR;
            END_XOR: state <= IDLE;
            default: state <= IDLE;
          endcase
        end
      end
    end
  end
endmodule
