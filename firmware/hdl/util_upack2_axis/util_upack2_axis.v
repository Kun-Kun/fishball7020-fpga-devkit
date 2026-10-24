// Complex AXI4-Stream adapter for the ADI TX DMA's four 16-bit lanes.
// TDATA[15:0] is I and TDATA[31:16] is Q on each output channel.
// SPDX-License-Identifier: BSD-1-Clause

`timescale 1ns/100ps

module util_upack2_axis #(
  parameter NUM_OF_CHANNELS = 2
) (
  input         clk,
  input         reset,

  input  [63:0] s_axis_data,
  input         s_axis_valid,
  output        s_axis_ready,

  output [31:0] m_axis_0_tdata,
  output        m_axis_0_tvalid,
  input         m_axis_0_tready,

  output [31:0] m_axis_1_tdata,
  output        m_axis_1_tvalid,
  input         m_axis_1_tready
);

  reg [31:0] channel_0_fifo [0:1];
  reg channel_0_read_pointer;
  reg channel_0_write_pointer;
  reg [1:0] channel_0_count;
  reg [1:0] channel_1_count;

  wire push;
  wire pop_0;

  // Two registered slots on each output break the ready path back to the
  // DMA memory interface while preserving independent output backpressure.
  assign s_axis_ready = (channel_0_count != 2'd2) &&
                        ((NUM_OF_CHANNELS == 1) || (channel_1_count != 2'd2));
  assign push = s_axis_valid && s_axis_ready;
  assign m_axis_0_tvalid = channel_0_count != 2'd0;
  assign m_axis_0_tdata = channel_0_fifo[channel_0_read_pointer];
  assign pop_0 = m_axis_0_tvalid && m_axis_0_tready;

  always @(posedge clk) begin
    if (reset) begin
      channel_0_read_pointer <= 1'b0;
      channel_0_write_pointer <= 1'b0;
      channel_0_count <= 2'd0;
    end else begin
      if (push) begin
        channel_0_fifo[channel_0_write_pointer] <= s_axis_data[31:0];
        channel_0_write_pointer <= ~channel_0_write_pointer;
      end
      if (pop_0)
        channel_0_read_pointer <= ~channel_0_read_pointer;

      case ({push, pop_0})
        2'b10: channel_0_count <= channel_0_count + 1'b1;
        2'b01: channel_0_count <= channel_0_count - 1'b1;
        default: channel_0_count <= channel_0_count;
      endcase
    end
  end

  generate if (NUM_OF_CHANNELS > 1) begin : g_channel_1
    reg [31:0] fifo [0:1];
    reg read_pointer;
    reg write_pointer;
    wire pop;

    assign m_axis_1_tvalid = channel_1_count != 2'd0;
    assign m_axis_1_tdata = fifo[read_pointer];
    assign pop = m_axis_1_tvalid && m_axis_1_tready;

    always @(posedge clk) begin
      if (reset) begin
        read_pointer <= 1'b0;
        write_pointer <= 1'b0;
        channel_1_count <= 2'd0;
      end else begin
        if (push) begin
          fifo[write_pointer] <= s_axis_data[63:32];
          write_pointer <= ~write_pointer;
        end
        if (pop)
          read_pointer <= ~read_pointer;

        case ({push, pop})
          2'b10: channel_1_count <= channel_1_count + 1'b1;
          2'b01: channel_1_count <= channel_1_count - 1'b1;
          default: channel_1_count <= channel_1_count;
        endcase
      end
    end
  end else begin : g_no_channel_1
    assign m_axis_1_tdata = 32'b0;
    assign m_axis_1_tvalid = 1'b0;
  end endgenerate
endmodule
