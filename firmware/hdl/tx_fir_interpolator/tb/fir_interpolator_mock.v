`timescale 1ns/1ps

// Small independent-ready model used to exercise the complex input fork.
module fir_interpolator (
  input         aclk,
  input         s_axis_data_tvalid,
  output        s_axis_data_tready,
  input  [15:0] s_axis_data_tdata,
  output reg    m_axis_data_tvalid = 1'b0,
  input         m_axis_data_tready,
  output reg [15:0] m_axis_data_tdata = 16'b0
);
  reg [1:0] q_phase = 2'b0;
  integer accepted = 0;

  always @(posedge aclk)
    q_phase <= q_phase + 1'b1;

  // I accepts continuously. Q accepts only once every four clocks.
  assign s_axis_data_tready = s_axis_data_tdata[15] ? (q_phase == 2'b10) : 1'b1;

  always @(posedge aclk) begin
    if (s_axis_data_tvalid && s_axis_data_tready) begin
      accepted <= accepted + 1;
      m_axis_data_tdata <= s_axis_data_tdata;
      m_axis_data_tvalid <= 1'b1;
    end else if (m_axis_data_tready) begin
      m_axis_data_tvalid <= 1'b0;
    end
  end
endmodule
