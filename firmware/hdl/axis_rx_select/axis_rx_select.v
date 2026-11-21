`timescale 1ns/100ps

// Select raw external-LO beat samples or the FPGA complex-multiplier result.
// The unselected product is drained. Raw samples still feed the multiplier
// during bypass so its TX2 reference input cannot back up and stall TX DMA.
// Software changes bypass between acquisitions.
module axis_rx_select (
  input clk,
  input reset,
  input bypass,
  input [31:0] s_axis_raw_tdata,
  input s_axis_raw_tvalid,
  output s_axis_raw_tready,
  output [31:0] m_axis_multiply_tdata,
  output m_axis_multiply_tvalid,
  input m_axis_multiply_tready,
  input [79:0] s_axis_product_tdata,
  input s_axis_product_tvalid,
  output s_axis_product_tready,
  output [79:0] m_axis_tdata,
  output m_axis_tvalid,
  input m_axis_tready
);
  (* ASYNC_REG = "TRUE" *) reg bypass_meta;
  (* ASYNC_REG = "TRUE" *) reg bypass_sync;
  always @(posedge clk) begin
    if (reset) begin bypass_meta <= 0; bypass_sync <= 0; end
    else begin bypass_meta <= bypass; bypass_sync <= bypass_meta; end
  end
  reg [31:0] raw_data;
  reg multiply_valid, raw_valid;
  // CMPY's 33-bit real and imaginary fields are byte-aligned in an 80-bit
  // AXIS word. Place each raw signed sample at the same Q17 scale, so gain
  // and final 16-bit conversion have identical semantics in both modes.
  wire [32:0] raw_i_full = {{17{raw_data[15]}}, raw_data[15:0]} << 17;
  wire [32:0] raw_q_full = {{17{raw_data[31]}}, raw_data[31:16]} << 17;
  wire [79:0] raw_full = {{7{raw_q_full[32]}}, raw_q_full,
                          {7{raw_i_full[32]}}, raw_i_full};
  assign m_axis_multiply_tdata = raw_data;
  assign m_axis_multiply_tvalid = multiply_valid;
  assign s_axis_raw_tready = (!multiply_valid || m_axis_multiply_tready) &&
                             (!raw_valid || m_axis_tready);
  assign s_axis_product_tready = bypass_sync || m_axis_tready;
  assign m_axis_tdata = bypass_sync ? raw_full : s_axis_product_tdata;
  assign m_axis_tvalid = bypass_sync ? raw_valid : s_axis_product_tvalid;

  always @(posedge clk) begin
    if (reset) begin
      raw_data <= 0;
      multiply_valid <= 0;
      raw_valid <= 0;
    end else if (s_axis_raw_tready) begin
      multiply_valid <= s_axis_raw_tvalid;
      raw_valid <= s_axis_raw_tvalid && bypass_sync;
      if (s_axis_raw_tvalid) raw_data <= s_axis_raw_tdata;
    end else begin
      if (multiply_valid && m_axis_multiply_tready) multiply_valid <= 0;
      if (raw_valid && m_axis_tready) raw_valid <= 0;
    end
  end
endmodule
