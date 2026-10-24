`timescale 1ns/1ps

module iq_axis_tb;
  reg clk = 1'b0;
  reg reset = 1'b1;
  reg enable_i = 1'b0;
  reg enable_q = 1'b0;
  reg valid_i = 1'b0;
  reg valid_q = 1'b0;
  reg [15:0] data_i = 16'b0;
  reg [15:0] data_q = 16'b0;
  reg m_axis_ready = 1'b0;
  wire ready;
  wire overflow;
  wire m_axis_valid;
  wire [31:0] m_axis_data;

  iq_axis dut (.*);

  always #5 clk = ~clk;

  task tick;
    begin
      @(posedge clk); #1;
    end
  endtask

  initial begin
    tick;
    reset = 1'b0;
    m_axis_ready = 1'b1;
    enable_i = 1'b1;
    enable_q = 1'b1;
    valid_i = 1'b1;
    valid_q = 1'b1;
    data_i = 16'h1357;
    data_q = 16'h2468;
    tick;
    if (!m_axis_valid || m_axis_data != 32'h2468_1357) $fatal(1, "RX packing failed");

    m_axis_ready = 1'b0;
    data_i = 16'hdead;
    data_q = 16'hbeef;
    tick;
    if (!overflow || m_axis_data != 32'h2468_1357) $fatal(1, "RX stall handling failed");

    valid_i = 1'b0;
    valid_q = 1'b0;
    m_axis_ready = 1'b1;
    tick;
    if (m_axis_valid) $fatal(1, "RX valid did not clear");
    $display("iq_axis_tb PASS");
    $finish;
  end
endmodule
