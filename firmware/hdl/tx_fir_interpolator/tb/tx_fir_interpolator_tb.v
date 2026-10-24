`timescale 1ns/1ps

module tx_fir_interpolator_tb;
  reg aclk = 1'b0;
  reg reset = 1'b1;
  reg active = 1'b1;
  reg [31:0] s_axis_tdata = 32'b0;
  reg s_axis_tvalid = 1'b0;
  wire s_axis_tready;
  wire [31:0] m_axis_tdata;
  wire m_axis_tvalid;
  reg m_axis_tready = 1'b1;

  tx_fir_interpolator dut (.*);
  always #5 aclk = ~aclk;

  task send(input [31:0] beat);
    reg accepted;
    begin
      @(negedge aclk);
      s_axis_tdata = beat;
      s_axis_tvalid = 1'b1;
      accepted = 1'b0;
      while (!accepted) begin
        @(posedge aclk);
        accepted = s_axis_tready;
      end
      @(negedge aclk);
      s_axis_tvalid = 1'b0;
    end
  endtask

  initial begin
    repeat (3) @(posedge aclk);
    #1 reset = 1'b0;
    repeat (3) @(posedge aclk);

    send(32'h9234_1234);
    send(32'h9567_2345);
    send(32'h9abc_3456);

    wait (dut.fir_i.accepted == 3 && dut.fir_q.accepted == 3);
    repeat (8) @(posedge aclk);
    if (dut.fir_i.accepted != 3 || dut.fir_q.accepted != 3)
      $fatal(1, "I/Q accepted counts diverged or a beat was duplicated");

    $display("tx_fir_interpolator_tb PASS: three complex beats accepted once per lane");
    $finish;
  end

  initial begin
    #2000;
    $fatal(1, "timeout waiting for both FIR input handshakes");
  end
endmodule
