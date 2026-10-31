`timescale 1ns/1ps

module axis_delay_case #(
  parameter integer DELAY = 0,
  parameter integer DATA_WIDTH = 32,
  parameter integer USER_WIDTH = 1,
  parameter integer ENABLE_SIDEBANDS = 1
) (output reg done = 1'b0);
  localparam integer KEEP_WIDTH = (DATA_WIDTH + 7) / 8;
  localparam integer PAYLOAD_WIDTH = DATA_WIDTH + 2*KEEP_WIDTH + USER_WIDTH + 3 + 2 + 1;

  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg reset = 1'b1;
  reg s_axis_tvalid = 1'b0;
  wire s_axis_tready;
  reg [DATA_WIDTH-1:0] s_axis_tdata = 0;
  reg [KEEP_WIDTH-1:0] s_axis_tkeep = 0;
  reg [KEEP_WIDTH-1:0] s_axis_tstrb = 0;
  reg s_axis_tlast = 0;
  reg [USER_WIDTH-1:0] s_axis_tuser = 0;
  reg [2:0] s_axis_tid = 0;
  reg [1:0] s_axis_tdest = 0;
  wire m_axis_tvalid;
  reg m_axis_tready = 1'b0;
  wire [DATA_WIDTH-1:0] m_axis_tdata;
  wire [KEEP_WIDTH-1:0] m_axis_tkeep;
  wire [KEEP_WIDTH-1:0] m_axis_tstrb;
  wire m_axis_tlast;
  wire [USER_WIDTH-1:0] m_axis_tuser;
  wire [2:0] m_axis_tid;
  wire [1:0] m_axis_tdest;

  axis_delay #(
    .DELAY_CYCLES(DELAY), .DATA_WIDTH(DATA_WIDTH),
    .KEEP_WIDTH(KEEP_WIDTH), .USER_WIDTH(USER_WIDTH),
    .ID_WIDTH(3), .DEST_WIDTH(2),
    .ENABLE_SIDEBANDS(ENABLE_SIDEBANDS)
  ) dut (.*);

  reg [PAYLOAD_WIDTH-1:0] expected [0:511];
  integer accepted_at [0:511];
  integer head = 0, tail = 0, sequence = 0, cycle;
  reg held = 1'b0;
  reg output_stalled = 1'b0;
  reg [PAYLOAD_WIDTH-1:0] stalled_payload;
  wire [PAYLOAD_WIDTH-1:0] source_payload =
      {s_axis_tdata, s_axis_tkeep, s_axis_tstrb, s_axis_tlast,
       s_axis_tuser, s_axis_tid, s_axis_tdest};
  wire [PAYLOAD_WIDTH-1:0] expected_payload = ENABLE_SIDEBANDS ?
      source_payload : {s_axis_tdata, {KEEP_WIDTH{1'b1}},
                        {KEEP_WIDTH{1'b1}}, 1'b0, {USER_WIDTH{1'b0}},
                        3'b0, 2'b0};
  wire [PAYLOAD_WIDTH-1:0] sink_payload =
      {m_axis_tdata, m_axis_tkeep, m_axis_tstrb, m_axis_tlast,
       m_axis_tuser, m_axis_tid, m_axis_tdest};

  initial begin
    repeat (2) @(negedge clk);
    reset = 1'b0;
    for (cycle = 0; cycle < 350; cycle = cycle + 1) begin
      @(negedge clk);
      reset = (cycle == 150);
      m_axis_tready = (cycle < 60 || cycle >= 290 ||
                       (cycle % 23 >= 6 && cycle % 7 != 0));
      if (!held) begin
        s_axis_tvalid = (cycle < 60) ? (cycle % 4 != 0) :
                        (cycle < 280 && cycle % 5 != 0);
        if (s_axis_tvalid) begin
          sequence = sequence + 1;
          s_axis_tdata = sequence * 32'h9e37_79b9;
          s_axis_tkeep = sequence ^ (sequence >> 3);
          s_axis_tstrb = ~(sequence >> 1);
          s_axis_tlast = (sequence % 7 == 0);
          s_axis_tuser = sequence * 13;
          s_axis_tid = sequence;
          s_axis_tdest = sequence >> 2;
        end
      end

      @(posedge clk);
      if (reset) begin
        if (s_axis_tready || m_axis_tvalid)
          $fatal(1, "delay %0d: reset did not suppress handshakes", DELAY);
        head = 0;
        tail = 0;
        held = 1'b0;
        output_stalled = 1'b0;
      end else begin
        if (output_stalled &&
            (!m_axis_tvalid || sink_payload !== stalled_payload))
          $fatal(1, "delay %0d: stalled output changed", DELAY);
        if (s_axis_tvalid && s_axis_tready) begin
          expected[tail] = expected_payload;
          accepted_at[tail] = cycle;
          tail = tail + 1;
        end
        if (m_axis_tvalid && m_axis_tready) begin
          if (head == tail || sink_payload !== expected[head])
            $fatal(1, "delay %0d: beat lost, reordered, or corrupted at cycle %0d", DELAY, cycle);
          if (cycle - accepted_at[head] < DELAY ||
              (cycle < 60 && cycle - accepted_at[head] != DELAY))
            $fatal(1, "delay %0d: wrong latency at cycle %0d", DELAY, cycle);
          head = head + 1;
        end
        held = s_axis_tvalid && !s_axis_tready;
        output_stalled = m_axis_tvalid && !m_axis_tready;
        stalled_payload = sink_payload;
      end
    end
    if (head != tail || held || output_stalled)
      $fatal(1, "delay %0d: stream did not drain", DELAY);
    done = 1'b1;
  end
endmodule

module axis_delay_tb;
  wire done0, done1, done4, done16, done40, done40_data;
  axis_delay_case #(.DELAY(0), .DATA_WIDTH(8), .USER_WIDTH(1)) c0(done0);
  axis_delay_case #(.DELAY(1), .DATA_WIDTH(32), .USER_WIDTH(4)) c1(done1);
  axis_delay_case #(.DELAY(4), .DATA_WIDTH(64), .USER_WIDTH(9)) c4(done4);
  axis_delay_case #(.DELAY(16), .DATA_WIDTH(32), .USER_WIDTH(1)) c16(done16);
  axis_delay_case #(.DELAY(40), .DATA_WIDTH(32), .USER_WIDTH(1)) c40(done40);
  axis_delay_case #(.DELAY(40), .DATA_WIDTH(32), .USER_WIDTH(1),
                    .ENABLE_SIDEBANDS(0)) c40_data(done40_data);

  initial begin
    wait (done0 && done1 && done4 && done16 && done40 && done40_data);
    $display("axis_delay_tb PASS");
    $finish;
  end
endmodule
