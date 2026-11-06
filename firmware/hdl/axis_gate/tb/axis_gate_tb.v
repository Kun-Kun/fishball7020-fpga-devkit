`timescale 1ns/1ps

module axis_gate_tb;
  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;
  reg start = 0;
  reg stop = 0;
  reg abort = 0;
  reg bypass = 0;
  reg s_axis_tvalid = 0;
  wire s_axis_tready;
  reg [31:0] s_axis_tdata = 0;
  wire m_axis_tvalid;
  reg m_axis_tready = 0;
  wire [31:0] m_axis_tdata;
  wire active, done;

  axis_gate dut (.*);

  initial begin
    repeat (3) @(negedge clk);
    reset = 0;
    s_axis_tvalid = 1;
    s_axis_tdata = 32'h11111111;
    repeat (3) @(negedge clk);
    if (!s_axis_tready || m_axis_tvalid || active || done)
      $fatal(1, "closed gate did not discard samples");

    start = 1;
    repeat (3) @(negedge clk);
    start = 0;
    if (!active || done)
      $fatal(1, "start did not open gate");

    s_axis_tdata = 32'h12345678;
    @(negedge clk);
    if (!m_axis_tvalid || m_axis_tdata !== 32'h12345678)
      $fatal(1, "sample not forwarded");
    s_axis_tdata = 32'h87654321;
    @(negedge clk);
    if (s_axis_tready || !m_axis_tvalid || m_axis_tdata !== 32'h12345678)
      $fatal(1, "stalled output changed or upstream was not stalled");

    // A 2 ns MUXOUT pulse falls entirely between stream clock edges.
    #1 stop = 1;
    #2 stop = 0;
    repeat (5) @(negedge clk);
    if (active || !done || !s_axis_tready || !m_axis_tvalid ||
        m_axis_tdata !== 32'h12345678)
      $fatal(1, "short stop pulse was missed or pending beat was lost");

    m_axis_tready = 1;
    @(negedge clk);
    if (m_axis_tvalid)
      $fatal(1, "closed gate forwarded a new sample");
    repeat (3) @(negedge clk);
    if (!done) $fatal(1, "done was not sticky");

    bypass = 1;
    s_axis_tdata = 32'habcdef01;
    @(negedge clk);
    if (!m_axis_tvalid || m_axis_tdata !== 32'habcdef01 || active)
      $fatal(1, "bypass did not forward while gate was closed");
    bypass = 0;
    @(negedge clk);
    if (m_axis_tvalid) $fatal(1, "bypass did not close");

    start = 1;
    repeat (3) @(negedge clk);
    start = 0;
    if (!active || done)
      $fatal(1, "second start did not clear done");

    abort = 1;
    @(negedge clk);
    abort = 0;
    if (active || done)
      $fatal(1, "abort must close gate without reporting ramp completion");

    reset = 1;
    @(negedge clk);
    if (active || done || m_axis_tvalid || s_axis_tready)
      $fatal(1, "reset did not close the gate");
    $display("axis_gate_tb PASS");
    $finish;
  end
endmodule
