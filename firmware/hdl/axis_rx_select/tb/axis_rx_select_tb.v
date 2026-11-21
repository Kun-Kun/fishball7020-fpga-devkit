`timescale 1ns/1ps
module axis_rx_select_tb;
  reg clk = 0; always #5 clk = ~clk;
  reg reset = 1, bypass = 0;
  reg [31:0] s_axis_raw_tdata = 32'hfffd0002;
  reg s_axis_raw_tvalid = 1;
  wire s_axis_raw_tready;
  wire [31:0] m_axis_multiply_tdata;
  wire m_axis_multiply_tvalid;
  reg m_axis_multiply_tready = 1;
  reg [79:0] s_axis_product_tdata = 80'h123456789abcde012345;
  reg s_axis_product_tvalid = 1;
  wire s_axis_product_tready;
  wire [79:0] m_axis_tdata;
  wire m_axis_tvalid;
  reg m_axis_tready = 1;
  axis_rx_select dut (.*);
  initial begin
    repeat (2) @(negedge clk); reset = 0;
    repeat (3) @(negedge clk);
    if (m_axis_tdata !== s_axis_product_tdata || !m_axis_tvalid ||
        !m_axis_multiply_tvalid || m_axis_multiply_tdata !== s_axis_raw_tdata)
      $fatal(1, "full-precision multiplier path failed");
    bypass = 1;
    repeat (3) @(negedge clk);
    if (m_axis_tdata[32:0] !== (33'sd2 <<< 17) ||
        m_axis_tdata[72:40] !== (-33'sd3 <<< 17) || !m_axis_tvalid ||
        !m_axis_multiply_tvalid || !s_axis_product_tready)
      $fatal(1, "scaled raw path failed");
    m_axis_tready = 0;
    #1;
    if (s_axis_raw_tready || !s_axis_product_tready)
      $fatal(1, "bypass backpressure failed");
    $display("axis_rx_select_tb PASS"); $finish;
  end
endmodule
