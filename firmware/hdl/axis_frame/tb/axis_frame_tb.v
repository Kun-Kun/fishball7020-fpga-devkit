`timescale 1ns/1ps
module axis_frame_tb;
  reg clk=0;
  always #5 clk=~clk;
  reg reset=1, start=0, stop=0, abort=0, bypass=0;
  reg s_axis_tvalid=0, m_axis_tready=1;
  reg [31:0] s_axis_tdata=0;
  wire s_axis_tready, m_axis_tvalid;
  wire [31:0] m_axis_tdata;
  axis_frame dut (.*);
  integer seen=0;
  reg recording=0;
  reg [31:0] expected [0:11];
  always @(posedge clk) begin
    if (!reset && m_axis_tvalid && m_axis_tready) begin
      if (m_axis_tdata == 32'hf15acafe && !recording) recording <= 1;
      if (recording) begin
        if (seen > 11 || m_axis_tdata !== expected[seen])
          $fatal(1,"framing mismatch at %0d: %h expected %h",seen,m_axis_tdata,expected[seen]);
        seen <= seen+1;
        if (seen == 11) recording <= 0;
      end
    end
  end
  task send(input [31:0] data);
    begin
      @(negedge clk); s_axis_tdata=data; s_axis_tvalid=1;
      do @(posedge clk); while (!s_axis_tready);
      @(negedge clk); s_axis_tvalid=0;
    end
  endtask
  initial begin
    expected[0]=32'h53544152;
    expected[1]=1;
    expected[2]=32'h12345678;
    expected[3]=32'hf15acafd;
    expected[4]=32'hf15acafe;
    expected[5]=32'hf15acafd;
    expected[6]=32'hf15acafd;
    expected[7]=32'hf15acafe;
    expected[8]=32'h454e4421;
    expected[9]=1;
    expected[10]=3;
    expected[11]=32'h12345678 ^ 32'hf15acafe ^ 32'hf15acafd;
    repeat(3) @(negedge clk); reset=0;
    @(negedge clk); start=1;
    repeat(4) @(negedge clk); start=0;
    send(32'h12345678);
    m_axis_tready=0;
    fork
      send(32'hf15acafe);
      begin
        repeat(4) @(negedge clk);
        m_axis_tready=1;
      end
    join
    send(32'hf15acafd);
    #1 stop=1; #2 stop=0;
    repeat(550) @(negedge clk);
    if (seen != 12) $fatal(1,"incomplete frame: %0d words",seen);
    bypass=1; s_axis_tvalid=1; s_axis_tdata=32'hdeadbeef;
    repeat(3) @(negedge clk);
    if (!m_axis_tvalid || m_axis_tdata !== 32'hdeadbeef)
      $fatal(1,"bypass altered a continuous IQ word");
    $display("axis_frame_tb PASS"); $finish;
  end
endmodule
