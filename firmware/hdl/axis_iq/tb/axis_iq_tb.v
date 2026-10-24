`timescale 1ns/1ps

module axis_iq_tb;
  reg clk = 1'b0;
  reg reset = 1'b1;
  reg s_axis_valid = 1'b0;
  wire s_axis_ready;
  reg [31:0] s_axis_data = 32'b0;
  reg enable_i = 1'b0;
  reg enable_q = 1'b0;
  reg request_i = 1'b0;
  reg request_q = 1'b0;
  wire valid_i;
  wire valid_q;
  wire [15:0] data_i;
  wire [15:0] data_q;
  wire underflow;

  axis_iq dut (.*);

  always #5 clk = ~clk;

  task tick;
    begin
      @(posedge clk); #1;
    end
  endtask

  initial begin
    tick;
    reset = 1'b0;
    enable_i = 1'b1;
    enable_q = 1'b1;
    s_axis_data = 32'hbeef_cafe;
    s_axis_valid = 1'b1;
    tick;
    s_axis_valid = 1'b0;
    request_i = 1'b1;
    request_q = 1'b1;
    tick;
    if (!valid_i || !valid_q || data_i != 16'hcafe || data_q != 16'hbeef)
      $fatal(1, "TX unpacking failed");

    tick;
    if (valid_i || valid_q || !underflow) $fatal(1, "TX underflow handling failed");
    $display("axis_iq_tb PASS");
    $finish;
  end
endmodule
