// Signed, saturating gain from full-precision CMPY or scaled raw RX samples.
// CMPY outputs two 33-bit components in byte-aligned 40-bit fields. Dividing
// by 2^17 reproduces its former 16-bit truncation; reducing that divisor by
// beat_shift recovers low product bits that were previously discarded.
`timescale 1ns/100ps

module axis_gain_shift (
  input clk,
  input reset,
  input [3:0] shift,
  input [79:0] s_axis_tdata,
  input s_axis_tvalid,
  output s_axis_tready,
  output [31:0] m_axis_tdata,
  output m_axis_tvalid,
  input m_axis_tready
);
  // GPIO is in the PS clock domain. A two-stage bus synchronizer is safe
  // because software only changes the field between acquisitions.
  (* ASYNC_REG = "TRUE" *) reg [3:0] shift_meta;
  (* ASYNC_REG = "TRUE" *) reg [3:0] shift_sync;
  always @(posedge clk) begin
    if (reset) begin
      shift_meta <= 0;
      shift_sync <= 0;
    end else begin
      shift_meta <= shift;
      shift_sync <= shift_meta;
    end
  end

  function [15:0] saturate;
    input signed [32:0] wide;
    begin
      if (wide > 33'sd32767)
        saturate = 16'h7fff;
      else if (wide < -33'sd32768)
        saturate = 16'h8000;
      else
        saturate = wide[15:0];
    end
  endfunction

  reg signed [32:0] wide_i, wide_q;
  wire [4:0] drop_bits = 5'd17 - {1'b0, shift_sync};
  reg first_valid;
  reg [31:0] data_reg;
  reg valid_reg;
  wire output_ready = !valid_reg || m_axis_tready;
  assign s_axis_tready = !first_valid || output_ready;
  assign m_axis_tdata = data_reg;
  assign m_axis_tvalid = valid_reg;

  always @(posedge clk) begin
    if (reset) begin
      data_reg <= 0;
      valid_reg <= 0;
      first_valid <= 0;
      wide_i <= 0;
      wide_q <= 0;
    end else begin
      if (output_ready) begin
        valid_reg <= first_valid;
        if (first_valid)
          data_reg <= {saturate(wide_q), saturate(wide_i)};
      end
      if (s_axis_tready) begin
        first_valid <= s_axis_tvalid;
        if (s_axis_tvalid) begin
          wide_i <= $signed(s_axis_tdata[32:0]) >>> drop_bits;
          wide_q <= $signed(s_axis_tdata[72:40]) >>> drop_bits;
        end
      end
    end
  end
endmodule
