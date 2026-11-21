`timescale 1ns/100ps
module axis_fifo4_tb;
  reg clk = 0, reset = 1, in_valid = 0, out_ready = 0;
  reg [31:0] in_data = 0;
  wire in_ready, out_valid;
  wire [31:0] out_data;
  integer sent = 0, received = 0, cycle = 0;
  always #5 clk = ~clk;
  axis_fifo4 dut (
    .clk(clk), .reset(reset),
    .s_axis_tdata(in_data), .s_axis_tvalid(in_valid), .s_axis_tready(in_ready),
    .m_axis_tdata(out_data), .m_axis_tvalid(out_valid), .m_axis_tready(out_ready)
  );
  initial begin
    repeat (3) @(negedge clk);
    reset = 0;
    while (received < 128) begin
      @(negedge clk);
      in_valid = sent < 128 && cycle % 11 != 7;
      in_data = 32'h12340000 + sent;
      out_ready = cycle % 19 >= 8;
      #1;
      @(posedge clk);
      if (in_valid && in_ready) sent = sent + 1;
      if (out_valid && out_ready) begin
        if (out_data !== 32'h12340000 + received)
          $fatal(1, "FIFO reordered sample %d", received);
        received = received + 1;
      end
      cycle = cycle + 1;
      if (cycle > 3000) $fatal(1, "FIFO stalled");
    end
    if (sent != 128) $fatal(1, "FIFO lost input samples");
    $display("axis_fifo4_tb PASS");
    $finish;
  end
endmodule
