`timescale 1ns/1ps
module axis_gain_shift_tb;
  reg clk = 0; always #5 clk = ~clk;
  reg reset = 1;
  reg [3:0] shift = 0;
  reg [79:0] s_axis_tdata = 0;
  reg s_axis_tvalid = 0;
  wire s_axis_tready;
  wire [31:0] m_axis_tdata;
  wire m_axis_tvalid;
  reg m_axis_tready = 1;
  axis_gain_shift dut (.*);

  function [79:0] pack;
    input signed [32:0] re, im;
    begin pack = {{7{im[32]}}, im, {7{re[32]}}, re}; end
  endfunction

  task send_check;
    input [79:0] sample;
    input [31:0] expected;
    begin
      @(negedge clk);
      s_axis_tdata = sample;
      s_axis_tvalid = 1;
      @(posedge clk);
      @(negedge clk);
      s_axis_tvalid = 0;
      @(posedge clk);
      #1;
      if (!m_axis_tvalid || m_axis_tdata !== expected)
        $fatal(1, "gain input=%h got=%h expected=%h", sample, m_axis_tdata, expected);
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    reset = 0;
    send_check(pack(33'sd100 * 131072, -33'sd10 * 131072), 32'hfff60064);
    shift = 1;
    repeat (3) @(negedge clk);
    send_check(pack(33'sd100 * 131072 + 65536,
                    -33'sd10 * 131072 - 65536), 32'hffeb00c9);
    shift = 15;
    repeat (3) @(negedge clk);
    send_check(pack(33'sd4, -33'sd4), 32'hffff0001);
    send_check(pack(33'sd200000, -33'sd200000), 32'h80007fff);
    shift = 1;
    repeat (3) @(negedge clk);
    @(negedge clk);
    m_axis_tready = 0;
    s_axis_tdata = pack(33'sd3 * 131072, 33'sd2 * 131072);
    s_axis_tvalid = 1;
    @(posedge clk);
    @(negedge clk);
    s_axis_tvalid = 0;
    @(posedge clk);
    #1;
    if (m_axis_tdata !== 32'h00040006 || !m_axis_tvalid)
      $fatal(1, "backpressure register failed");
    @(negedge clk);
    s_axis_tdata = pack(33'sd5 * 131072, 33'sd4 * 131072);
    s_axis_tvalid = 1;
    @(posedge clk);
    #1;
    if (m_axis_tdata !== 32'h00040006 || s_axis_tready)
      $fatal(1, "stalled output changed");
    @(negedge clk);
    s_axis_tvalid = 0;
    m_axis_tready = 1;
    @(posedge clk);
    #1;
    if (m_axis_tdata !== 32'h0008000a || !m_axis_tvalid)
      $fatal(1, "next sample lost on resume");
    $display("axis_gain_shift_tb PASS");
    $finish;
  end
endmodule
