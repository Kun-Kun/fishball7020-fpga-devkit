// ***************************************************************************
// Copyright (C) 2026 Fishball
// SPDX short identifier: BSD-1-Clause
// ***************************************************************************

`timescale 1ns/100ps

// AXI4-Stream front end for the ADI cpack2 engine. Each AXIS beat carries a
// complex sample: TDATA[15:0] is I and TDATA[31:16] is Q. NUM_OF_CHANNELS
// counts 16-bit I/Q lanes, so the core exposes NUM_OF_CHANNELS/2 AXIS ports
// and NUM_OF_CHANNELS lane-enable inputs.
module util_cpack2_axis #(
  parameter NUM_OF_CHANNELS = 4,
  parameter SAMPLES_PER_CHANNEL = 1,
  parameter SAMPLE_DATA_WIDTH = 16
) (
  input clk,
  input reset,
  input enable_0,
  input enable_1,
  input enable_2,
  input enable_3,
  input enable_4,
  input enable_5,
  input enable_6,
  input enable_7,
  input enable_8,
  input enable_9,
  input enable_10,
  input enable_11,
  input enable_12,
  input enable_13,
  input enable_14,
  input enable_15,
  input enable_16,
  input enable_17,
  input enable_18,
  input enable_19,
  input enable_20,
  input enable_21,
  input enable_22,
  input enable_23,
  input enable_24,
  input enable_25,
  input enable_26,
  input enable_27,
  input enable_28,
  input enable_29,
  input enable_30,
  input enable_31,
  input enable_32,
  input enable_33,
  input enable_34,
  input enable_35,
  input enable_36,
  input enable_37,
  input enable_38,
  input enable_39,
  input enable_40,
  input enable_41,
  input enable_42,
  input enable_43,
  input enable_44,
  input enable_45,
  input enable_46,
  input enable_47,
  input enable_48,
  input enable_49,
  input enable_50,
  input enable_51,
  input enable_52,
  input enable_53,
  input enable_54,
  input enable_55,
  input enable_56,
  input enable_57,
  input enable_58,
  input enable_59,
  input enable_60,
  input enable_61,
  input enable_62,
  input enable_63,
  input [31:0] s_axis_0_tdata,
  input s_axis_0_tvalid,
  output s_axis_0_tready,
  input [31:0] s_axis_1_tdata,
  input s_axis_1_tvalid,
  output s_axis_1_tready,
  input [31:0] s_axis_2_tdata,
  input s_axis_2_tvalid,
  output s_axis_2_tready,
  input [31:0] s_axis_3_tdata,
  input s_axis_3_tvalid,
  output s_axis_3_tready,
  input [31:0] s_axis_4_tdata,
  input s_axis_4_tvalid,
  output s_axis_4_tready,
  input [31:0] s_axis_5_tdata,
  input s_axis_5_tvalid,
  output s_axis_5_tready,
  input [31:0] s_axis_6_tdata,
  input s_axis_6_tvalid,
  output s_axis_6_tready,
  input [31:0] s_axis_7_tdata,
  input s_axis_7_tvalid,
  output s_axis_7_tready,
  input [31:0] s_axis_8_tdata,
  input s_axis_8_tvalid,
  output s_axis_8_tready,
  input [31:0] s_axis_9_tdata,
  input s_axis_9_tvalid,
  output s_axis_9_tready,
  input [31:0] s_axis_10_tdata,
  input s_axis_10_tvalid,
  output s_axis_10_tready,
  input [31:0] s_axis_11_tdata,
  input s_axis_11_tvalid,
  output s_axis_11_tready,
  input [31:0] s_axis_12_tdata,
  input s_axis_12_tvalid,
  output s_axis_12_tready,
  input [31:0] s_axis_13_tdata,
  input s_axis_13_tvalid,
  output s_axis_13_tready,
  input [31:0] s_axis_14_tdata,
  input s_axis_14_tvalid,
  output s_axis_14_tready,
  input [31:0] s_axis_15_tdata,
  input s_axis_15_tvalid,
  output s_axis_15_tready,
  input [31:0] s_axis_16_tdata,
  input s_axis_16_tvalid,
  output s_axis_16_tready,
  input [31:0] s_axis_17_tdata,
  input s_axis_17_tvalid,
  output s_axis_17_tready,
  input [31:0] s_axis_18_tdata,
  input s_axis_18_tvalid,
  output s_axis_18_tready,
  input [31:0] s_axis_19_tdata,
  input s_axis_19_tvalid,
  output s_axis_19_tready,
  input [31:0] s_axis_20_tdata,
  input s_axis_20_tvalid,
  output s_axis_20_tready,
  input [31:0] s_axis_21_tdata,
  input s_axis_21_tvalid,
  output s_axis_21_tready,
  input [31:0] s_axis_22_tdata,
  input s_axis_22_tvalid,
  output s_axis_22_tready,
  input [31:0] s_axis_23_tdata,
  input s_axis_23_tvalid,
  output s_axis_23_tready,
  input [31:0] s_axis_24_tdata,
  input s_axis_24_tvalid,
  output s_axis_24_tready,
  input [31:0] s_axis_25_tdata,
  input s_axis_25_tvalid,
  output s_axis_25_tready,
  input [31:0] s_axis_26_tdata,
  input s_axis_26_tvalid,
  output s_axis_26_tready,
  input [31:0] s_axis_27_tdata,
  input s_axis_27_tvalid,
  output s_axis_27_tready,
  input [31:0] s_axis_28_tdata,
  input s_axis_28_tvalid,
  output s_axis_28_tready,
  input [31:0] s_axis_29_tdata,
  input s_axis_29_tvalid,
  output s_axis_29_tready,
  input [31:0] s_axis_30_tdata,
  input s_axis_30_tvalid,
  output s_axis_30_tready,
  input [31:0] s_axis_31_tdata,
  input s_axis_31_tvalid,
  output s_axis_31_tready,
  output overflow,
  output packed_fifo_wr_en,
  input packed_fifo_wr_overflow,
  output packed_fifo_wr_sync,
  output [2**$clog2(NUM_OF_CHANNELS)*SAMPLE_DATA_WIDTH*SAMPLES_PER_CHANNEL-1:0] packed_fifo_wr_data
);

  localparam CHANNEL_DATA_WIDTH = SAMPLE_DATA_WIDTH * SAMPLES_PER_CHANNEL;
  localparam REAL_NUM_OF_CHANNELS = NUM_OF_CHANNELS > 32 ? 64 :
     NUM_OF_CHANNELS > 16 ? 32 :
     NUM_OF_CHANNELS > 8 ? 16 :
     NUM_OF_CHANNELS > 4 ? 8 :
     NUM_OF_CHANNELS > 2 ? 4 :
     NUM_OF_CHANNELS > 1 ? 2 : 1;
  localparam NUM_OF_AXIS_INPUTS = NUM_OF_CHANNELS / 2;

  wire [63:0] enable_s = {
    enable_63,
    enable_62,
    enable_61,
    enable_60,
    enable_59,
    enable_58,
    enable_57,
    enable_56,
    enable_55,
    enable_54,
    enable_53,
    enable_52,
    enable_51,
    enable_50,
    enable_49,
    enable_48,
    enable_47,
    enable_46,
    enable_45,
    enable_44,
    enable_43,
    enable_42,
    enable_41,
    enable_40,
    enable_39,
    enable_38,
    enable_37,
    enable_36,
    enable_35,
    enable_34,
    enable_33,
    enable_32,
    enable_31,
    enable_30,
    enable_29,
    enable_28,
    enable_27,
    enable_26,
    enable_25,
    enable_24,
    enable_23,
    enable_22,
    enable_21,
    enable_20,
    enable_19,
    enable_18,
    enable_17,
    enable_16,
    enable_15,
    enable_14,
    enable_13,
    enable_12,
    enable_11,
    enable_10,
    enable_9,
    enable_8,
    enable_7,
    enable_6,
    enable_5,
    enable_4,
    enable_3,
    enable_2,
    enable_1,
    enable_0
  };
  wire [REAL_NUM_OF_CHANNELS-1:0] enable = enable_s[REAL_NUM_OF_CHANNELS-1:0];
  wire [31:0] s_axis_valid;
  wire [31:0] s_axis_ready;
  wire [32*32-1:0] s_axis_data;
  wire [31:0] input_valid;
  wire [31:0] input_active;
  wire [31:0] input_valid_or_inactive;
  wire [CHANNEL_DATA_WIDTH*64-1:0] fifo_wr_data_s;
  wire [CHANNEL_DATA_WIDTH*REAL_NUM_OF_CHANNELS-1:0] fifo_wr_data;
  wire [REAL_NUM_OF_CHANNELS-1:0] fifo_wr_en;
  wire input_pair_active = |input_active[NUM_OF_AXIS_INPUTS-1:0];
  wire input_pair_valid = (&input_valid_or_inactive[NUM_OF_AXIS_INPUTS-1:0]) &
                          input_pair_active & ~reset;

  assign s_axis_data[32*0+:32] = s_axis_0_tdata;
  assign s_axis_valid[0] = s_axis_0_tvalid;
  assign s_axis_0_tready = s_axis_ready[0];
  assign s_axis_data[32*1+:32] = s_axis_1_tdata;
  assign s_axis_valid[1] = s_axis_1_tvalid;
  assign s_axis_1_tready = s_axis_ready[1];
  assign s_axis_data[32*2+:32] = s_axis_2_tdata;
  assign s_axis_valid[2] = s_axis_2_tvalid;
  assign s_axis_2_tready = s_axis_ready[2];
  assign s_axis_data[32*3+:32] = s_axis_3_tdata;
  assign s_axis_valid[3] = s_axis_3_tvalid;
  assign s_axis_3_tready = s_axis_ready[3];
  assign s_axis_data[32*4+:32] = s_axis_4_tdata;
  assign s_axis_valid[4] = s_axis_4_tvalid;
  assign s_axis_4_tready = s_axis_ready[4];
  assign s_axis_data[32*5+:32] = s_axis_5_tdata;
  assign s_axis_valid[5] = s_axis_5_tvalid;
  assign s_axis_5_tready = s_axis_ready[5];
  assign s_axis_data[32*6+:32] = s_axis_6_tdata;
  assign s_axis_valid[6] = s_axis_6_tvalid;
  assign s_axis_6_tready = s_axis_ready[6];
  assign s_axis_data[32*7+:32] = s_axis_7_tdata;
  assign s_axis_valid[7] = s_axis_7_tvalid;
  assign s_axis_7_tready = s_axis_ready[7];
  assign s_axis_data[32*8+:32] = s_axis_8_tdata;
  assign s_axis_valid[8] = s_axis_8_tvalid;
  assign s_axis_8_tready = s_axis_ready[8];
  assign s_axis_data[32*9+:32] = s_axis_9_tdata;
  assign s_axis_valid[9] = s_axis_9_tvalid;
  assign s_axis_9_tready = s_axis_ready[9];
  assign s_axis_data[32*10+:32] = s_axis_10_tdata;
  assign s_axis_valid[10] = s_axis_10_tvalid;
  assign s_axis_10_tready = s_axis_ready[10];
  assign s_axis_data[32*11+:32] = s_axis_11_tdata;
  assign s_axis_valid[11] = s_axis_11_tvalid;
  assign s_axis_11_tready = s_axis_ready[11];
  assign s_axis_data[32*12+:32] = s_axis_12_tdata;
  assign s_axis_valid[12] = s_axis_12_tvalid;
  assign s_axis_12_tready = s_axis_ready[12];
  assign s_axis_data[32*13+:32] = s_axis_13_tdata;
  assign s_axis_valid[13] = s_axis_13_tvalid;
  assign s_axis_13_tready = s_axis_ready[13];
  assign s_axis_data[32*14+:32] = s_axis_14_tdata;
  assign s_axis_valid[14] = s_axis_14_tvalid;
  assign s_axis_14_tready = s_axis_ready[14];
  assign s_axis_data[32*15+:32] = s_axis_15_tdata;
  assign s_axis_valid[15] = s_axis_15_tvalid;
  assign s_axis_15_tready = s_axis_ready[15];
  assign s_axis_data[32*16+:32] = s_axis_16_tdata;
  assign s_axis_valid[16] = s_axis_16_tvalid;
  assign s_axis_16_tready = s_axis_ready[16];
  assign s_axis_data[32*17+:32] = s_axis_17_tdata;
  assign s_axis_valid[17] = s_axis_17_tvalid;
  assign s_axis_17_tready = s_axis_ready[17];
  assign s_axis_data[32*18+:32] = s_axis_18_tdata;
  assign s_axis_valid[18] = s_axis_18_tvalid;
  assign s_axis_18_tready = s_axis_ready[18];
  assign s_axis_data[32*19+:32] = s_axis_19_tdata;
  assign s_axis_valid[19] = s_axis_19_tvalid;
  assign s_axis_19_tready = s_axis_ready[19];
  assign s_axis_data[32*20+:32] = s_axis_20_tdata;
  assign s_axis_valid[20] = s_axis_20_tvalid;
  assign s_axis_20_tready = s_axis_ready[20];
  assign s_axis_data[32*21+:32] = s_axis_21_tdata;
  assign s_axis_valid[21] = s_axis_21_tvalid;
  assign s_axis_21_tready = s_axis_ready[21];
  assign s_axis_data[32*22+:32] = s_axis_22_tdata;
  assign s_axis_valid[22] = s_axis_22_tvalid;
  assign s_axis_22_tready = s_axis_ready[22];
  assign s_axis_data[32*23+:32] = s_axis_23_tdata;
  assign s_axis_valid[23] = s_axis_23_tvalid;
  assign s_axis_23_tready = s_axis_ready[23];
  assign s_axis_data[32*24+:32] = s_axis_24_tdata;
  assign s_axis_valid[24] = s_axis_24_tvalid;
  assign s_axis_24_tready = s_axis_ready[24];
  assign s_axis_data[32*25+:32] = s_axis_25_tdata;
  assign s_axis_valid[25] = s_axis_25_tvalid;
  assign s_axis_25_tready = s_axis_ready[25];
  assign s_axis_data[32*26+:32] = s_axis_26_tdata;
  assign s_axis_valid[26] = s_axis_26_tvalid;
  assign s_axis_26_tready = s_axis_ready[26];
  assign s_axis_data[32*27+:32] = s_axis_27_tdata;
  assign s_axis_valid[27] = s_axis_27_tvalid;
  assign s_axis_27_tready = s_axis_ready[27];
  assign s_axis_data[32*28+:32] = s_axis_28_tdata;
  assign s_axis_valid[28] = s_axis_28_tvalid;
  assign s_axis_28_tready = s_axis_ready[28];
  assign s_axis_data[32*29+:32] = s_axis_29_tdata;
  assign s_axis_valid[29] = s_axis_29_tvalid;
  assign s_axis_29_tready = s_axis_ready[29];
  assign s_axis_data[32*30+:32] = s_axis_30_tdata;
  assign s_axis_valid[30] = s_axis_30_tvalid;
  assign s_axis_30_tready = s_axis_ready[30];
  assign s_axis_data[32*31+:32] = s_axis_31_tdata;
  assign s_axis_valid[31] = s_axis_31_tvalid;
  assign s_axis_31_tready = s_axis_ready[31];

  genvar i;
  generate
    for (i = 0; i < 32; i = i + 1) begin: gen_axis_inputs
      if (i < NUM_OF_AXIS_INPUTS) begin: gen_active_axis
        assign input_active[i] = enable[2*i] | enable[2*i+1];
        assign input_valid_or_inactive[i] = input_valid[i] | ~input_active[i];
        assign input_valid[i] = s_axis_valid[i];
        assign s_axis_ready[i] = input_active[i] ? input_pair_valid : 1'b1;
        assign fifo_wr_data_s[CHANNEL_DATA_WIDTH*(2*i)+:CHANNEL_DATA_WIDTH] = s_axis_data[32*i+:16];
        assign fifo_wr_data_s[CHANNEL_DATA_WIDTH*(2*i+1)+:CHANNEL_DATA_WIDTH] = s_axis_data[32*i+16+:16];
      end else begin: gen_unused_axis
        assign input_active[i] = 1'b0;
        assign input_valid_or_inactive[i] = 1'b1;
        assign input_valid[i] = 1'b1;
        assign s_axis_ready[i] = 1'b0;
        assign fifo_wr_data_s[CHANNEL_DATA_WIDTH*(2*i)+:CHANNEL_DATA_WIDTH] = {CHANNEL_DATA_WIDTH{1'b0}};
        assign fifo_wr_data_s[CHANNEL_DATA_WIDTH*(2*i+1)+:CHANNEL_DATA_WIDTH] = {CHANNEL_DATA_WIDTH{1'b0}};
      end
    end
  endgenerate

  assign fifo_wr_data = fifo_wr_data_s[CHANNEL_DATA_WIDTH*REAL_NUM_OF_CHANNELS-1:0];
  assign fifo_wr_en = {REAL_NUM_OF_CHANNELS{input_pair_valid}};
  assign overflow = packed_fifo_wr_overflow;

  util_cpack2_impl #(
    .NUM_OF_CHANNELS(NUM_OF_CHANNELS),
    .SAMPLES_PER_CHANNEL(SAMPLES_PER_CHANNEL),
    .SAMPLE_DATA_WIDTH(SAMPLE_DATA_WIDTH)
  ) i_cpack2_impl (
    .clk(clk),
    .reset(reset),
    .enable(enable),
    .fifo_wr_en(fifo_wr_en),
    .fifo_wr_overflow(),
    .fifo_wr_data(fifo_wr_data),
    .packed_fifo_wr_en(packed_fifo_wr_en),
    .packed_fifo_wr_overflow(packed_fifo_wr_overflow),
    .packed_fifo_wr_sync(packed_fifo_wr_sync),
    .packed_fifo_wr_data(packed_fifo_wr_data)
  );
endmodule
