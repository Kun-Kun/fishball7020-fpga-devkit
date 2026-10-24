// ***************************************************************************
// Local dual-channel Pluto RX decimator.
// SPDX short identifier: BSD-1-Clause
// ***************************************************************************

`timescale 1ns/100ps

module util_fir_dec #(
  parameter NUM_OF_CHANNELS = 2
) (
  input aclk,
  input reset,
  input active_0,
  input active_1,
  input enable_in_0,
  input enable_in_1,
  output enable_out_0,
  output enable_out_1,

  input  [31:0] s_axis_0_tdata,
  input         s_axis_0_tvalid,
  output        s_axis_0_tready,
  output [31:0] m_axis_0_tdata,
  output        m_axis_0_tvalid,
  input         m_axis_0_tready,

  input  [31:0] s_axis_1_tdata,
  input         s_axis_1_tvalid,
  output        s_axis_1_tready,
  output [31:0] m_axis_1_tdata,
  output        m_axis_1_tvalid,
  input         m_axis_1_tready
);

  assign enable_out_0 = enable_in_0;
  assign enable_out_1 = enable_in_1;

  wire active_0_sync;
  wire active_1_sync;

  generate
    if (NUM_OF_CHANNELS > 0) begin: gen_channel_0
      sync_bits active_sync (
        .in_bits(active_0),
        .out_resetn(~reset),
        .out_clk(aclk),
        .out_bits(active_0_sync)
      );

      util_fir_dec_channel channel (
        .aclk(aclk),
        .active(active_0_sync),
        .s_axis_tdata(s_axis_0_tdata),
        .s_axis_tvalid(s_axis_0_tvalid),
        .s_axis_tready(s_axis_0_tready),
        .m_axis_tdata(m_axis_0_tdata),
        .m_axis_tvalid(m_axis_0_tvalid),
        .m_axis_tready(m_axis_0_tready)
      );
    end else begin: gen_no_channel_0
      assign active_0_sync = 1'b0;
      assign s_axis_0_tready = 1'b0;
      assign m_axis_0_tdata = 32'b0;
      assign m_axis_0_tvalid = 1'b0;
    end

    if (NUM_OF_CHANNELS > 1) begin: gen_channel_1
      sync_bits active_sync (
        .in_bits(active_1),
        .out_resetn(~reset),
        .out_clk(aclk),
        .out_bits(active_1_sync)
      );

      util_fir_dec_channel channel (
        .aclk(aclk),
        .active(active_1_sync),
        .s_axis_tdata(s_axis_1_tdata),
        .s_axis_tvalid(s_axis_1_tvalid),
        .s_axis_tready(s_axis_1_tready),
        .m_axis_tdata(m_axis_1_tdata),
        .m_axis_tvalid(m_axis_1_tvalid),
        .m_axis_tready(m_axis_1_tready)
      );
    end else begin: gen_no_channel_1
      assign active_1_sync = 1'b0;
      assign s_axis_1_tready = 1'b0;
      assign m_axis_1_tdata = 32'b0;
      assign m_axis_1_tvalid = 1'b0;
    end
  endgenerate

endmodule

module util_fir_dec_channel (
  input aclk,
  input active,
  input  [31:0] s_axis_tdata,
  input         s_axis_tvalid,
  output        s_axis_tready,
  output [31:0] m_axis_tdata,
  output        m_axis_tvalid,
  input         m_axis_tready
);

  wire [31:0] fir_s_axis_tdata;
  wire fir_s_axis_tvalid;
  wire fir_s_axis_tready;
  wire [31:0] fir_m_axis_tdata;
  wire fir_m_axis_tvalid;
  wire fir_m_axis_tready;

  ad_axis_mux axis_mux (
    .aclk(aclk),
    .select_path(active),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .m_axis_to_fir_tdata(fir_s_axis_tdata),
    .m_axis_to_fir_tvalid(fir_s_axis_tvalid),
    .m_axis_to_fir_tready(fir_s_axis_tready),
    .s_axis_from_fir_tdata(fir_m_axis_tdata),
    .s_axis_from_fir_tvalid(fir_m_axis_tvalid),
    .s_axis_from_fir_tready(fir_m_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .data_out(),
    .valid_out()
  );

  fir_decim decimator (
    .aclk(aclk),
    .s_axis_data_tvalid(fir_s_axis_tvalid),
    .s_axis_data_tready(fir_s_axis_tready),
    .s_axis_data_tdata(fir_s_axis_tdata),
    .m_axis_data_tvalid(fir_m_axis_tvalid),
    .m_axis_data_tready(fir_m_axis_tready),
    .m_axis_data_tdata(fir_m_axis_tdata)
  );

endmodule
