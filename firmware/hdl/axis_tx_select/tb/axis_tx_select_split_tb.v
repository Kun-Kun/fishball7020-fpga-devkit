`timescale 1ns/100ps
module axis_tx_select_split_tb;
  reg clk = 0, reset = 1, select_tx2 = 0;
  always #5 clk = ~clk;
  reg [31:0] tx1_data = 0, tx2_data = 0;
  reg tx1_valid = 0, tx2_valid = 0;
  wire tx1_ready, tx2_ready;
  wire [31:0] out1_data, out2_data, ref_data, ref1_data, ref2_data;
  wire out1_valid, out2_valid, ref_valid, ref_ready, ref1_valid, ref2_valid;
  reg out1_ready = 1, out2_ready = 1, ref1_ready = 1, ref2_ready = 1;

  axis_tx_select selector (
    .clk(clk), .reset(reset), .select_tx2(select_tx2),
    .s_axis_tx1_tdata(tx1_data), .s_axis_tx1_tvalid(tx1_valid), .s_axis_tx1_tready(tx1_ready),
    .s_axis_tx2_tdata(tx2_data), .s_axis_tx2_tvalid(tx2_valid), .s_axis_tx2_tready(tx2_ready),
    .m_axis_tx1_tdata(out1_data), .m_axis_tx1_tvalid(out1_valid), .m_axis_tx1_tready(out1_ready),
    .m_axis_tx2_tdata(out2_data), .m_axis_tx2_tvalid(out2_valid), .m_axis_tx2_tready(out2_ready),
    .m_axis_ref_tdata(ref_data), .m_axis_ref_tvalid(ref_valid), .m_axis_ref_tready(ref_ready)
  );
  axis_split split (
    .clk(clk), .reset(reset),
    .s_axis_tdata(ref_data), .s_axis_tvalid(ref_valid), .s_axis_tready(ref_ready),
    .m_axis_0_tdata(ref1_data), .m_axis_0_tvalid(ref1_valid), .m_axis_0_tready(ref1_ready),
    .m_axis_1_tdata(ref2_data), .m_axis_1_tvalid(ref2_valid), .m_axis_1_tready(ref2_ready)
  );

  task run_phase(input integer tx2_selected);
    integer sent1, sent2, got1, got2, got_ref1, got_ref2, cycles, base;
    begin
      select_tx2 = tx2_selected;
      tx1_valid = 0; tx2_valid = 0;
      out1_ready = 1; out2_ready = 1; ref1_ready = 1; ref2_ready = 1;
      repeat (6) @(negedge clk);
      sent1 = 0; sent2 = 0; got1 = 0; got2 = 0;
      got_ref1 = 0; got_ref2 = 0; cycles = 0;
      base = tx2_selected ? 2000 : 1000;
      while (got1 < 64 || got2 < 64 || got_ref1 < 64 || got_ref2 < 64) begin
        @(negedge clk);
        tx1_valid = sent1 < 64;
        tx2_valid = sent2 < 64;
        tx1_data = 1000 + sent1;
        tx2_data = 2000 + sent2;
        out1_ready = cycles % 7 != 2;
        out2_ready = cycles % 5 != 3;
        ref1_ready = cycles % 11 != 4;
        ref2_ready = cycles % 13 != 6;
        #1;
        @(posedge clk);
        if (tx1_valid && tx1_ready) sent1 = sent1 + 1;
        if (tx2_valid && tx2_ready) sent2 = sent2 + 1;
        if (out1_valid && out1_ready) begin
          if (out1_data !== 1000 + got1) $fatal(1, "TX1 data mismatch %d", got1);
          got1 = got1 + 1;
        end
        if (out2_valid && out2_ready) begin
          if (out2_data !== 2000 + got2) $fatal(1, "TX2 data mismatch %d", got2);
          got2 = got2 + 1;
        end
        if (ref1_valid && ref1_ready) begin
          if (ref1_data !== base + got_ref1) $fatal(1, "RX1 reference mismatch %d", got_ref1);
          got_ref1 = got_ref1 + 1;
        end
        if (ref2_valid && ref2_ready) begin
          if (ref2_data !== base + got_ref2) $fatal(1, "RX2 reference mismatch %d", got_ref2);
          got_ref2 = got_ref2 + 1;
        end
        cycles = cycles + 1;
        if (cycles > 2000) $fatal(1, "selector or splitter stalled");
      end
      @(negedge clk);
      tx1_valid = 0; tx2_valid = 0;
      if (sent1 != 64 || sent2 != 64) $fatal(1, "input count mismatch");
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    reset = 0;
    run_phase(0);
    run_phase(1);
    $display("axis_tx_select_split_tb PASS");
    $finish;
  end
endmodule
