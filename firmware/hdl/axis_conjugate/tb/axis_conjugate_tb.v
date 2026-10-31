`timescale 1ns/1ps

module axis_conjugate_tb;
  reg clk = 1'b0;
  reg reset = 1'b1;
  always #5 clk = ~clk;
  task tick; begin @(posedge clk); #1; end endtask

  reg s_axis_valid = 1'b0;
  wire s_axis_ready;
  reg [31:0] s_axis_data = 32'b0;
  wire m_axis_tx_valid, m_axis_conjugate_valid;
  reg m_axis_tx_ready = 1'b1, m_axis_conjugate_ready = 1'b1;
  wire [31:0] m_axis_tx_data, m_axis_conjugate_data;
  axis_conjugate dut (.*);

  reg solo_valid = 1'b0;
  wire solo_ready;
  reg [31:0] solo_data = 32'b0;
  wire solo_tx_valid, solo_conjugate_valid;
  wire [31:0] solo_tx_data, solo_conjugate_data;
  reg solo_conjugate_ready = 1'b1;
  axis_conjugate #(.ENABLE_M_AXIS_TX(0)) dut_no_tx (
    .clk(clk), .reset(reset),
    .s_axis_valid(solo_valid), .s_axis_ready(solo_ready),
    .s_axis_data(solo_data),
    .m_axis_tx_valid(solo_tx_valid), .m_axis_tx_ready(1'b0),
    .m_axis_tx_data(solo_tx_data),
    .m_axis_conjugate_valid(solo_conjugate_valid),
    .m_axis_conjugate_ready(solo_conjugate_ready),
    .m_axis_conjugate_data(solo_conjugate_data)
  );

  initial begin
    tick;
    reset = 1'b0;
    s_axis_data = 32'h4000_2000;
    s_axis_valid = 1'b1;
    tick;
    s_axis_valid = 1'b0;
    #1;
    if (!m_axis_tx_valid || !m_axis_conjugate_valid ||
        m_axis_tx_data !== 32'h4000_2000 ||
        m_axis_conjugate_data !== 32'hc000_2000)
      $fatal(1, "raw and conjugated streams are incorrectly formed");

    // The TX consumer takes beat 1 while CMPY stalls. It must not get beat 1
    // again, and the source must not advance before CMPY takes it.
    m_axis_conjugate_ready = 1'b0;
    tick;
    if (m_axis_tx_valid || !m_axis_conjugate_valid || s_axis_ready)
      $fatal(1, "TX beat repeated or stalled CMPY beat lost");

    // CMPY takes beat 1 while beat 2 replaces it in the elastic register.
    m_axis_conjugate_ready = 1'b1;
    s_axis_data = 32'h8000_0000;
    s_axis_valid = 1'b1;
    tick;
    s_axis_valid = 1'b0;
    if (!m_axis_tx_valid || !m_axis_conjugate_valid ||
        m_axis_conjugate_data !== 32'h7fff_0000)
      $fatal(1, "replacement or -1.0 saturation failed");

    // The opposite stall order must not repeat a CMPY beat either.
    m_axis_tx_ready = 1'b0;
    tick;
    if (m_axis_conjugate_valid || !m_axis_tx_valid || s_axis_ready)
      $fatal(1, "CMPY beat repeated or stalled TX beat lost");
    m_axis_tx_ready = 1'b1;
    tick;

    // With the optional TX output disabled, its unconnected TREADY must not
    // backpressure the sole conjugated output.
    solo_data = 32'h2000_1234;
    solo_valid = 1'b1;
    if (!solo_ready) $fatal(1, "disabled TX port blocked the input");
    tick;
    solo_valid = 1'b0;
    if (solo_tx_valid || solo_tx_data !== 32'b0 ||
        !solo_conjugate_valid || solo_conjugate_data !== 32'he000_1234)
      $fatal(1, "single-output configuration failed");
    solo_conjugate_ready = 1'b0;
    #1;
    if (solo_ready) $fatal(1, "conjugate output did not apply backpressure");
    solo_conjugate_ready = 1'b1;
    tick;
    if (solo_conjugate_valid)
      $fatal(1, "single-output sample repeated");

    $display("axis_conjugate_tb PASS");
    $finish;
  end
endmodule
