//七段数码管驱动，时分复用扫描8位数码管
module SSeg7(clk, rst, SW0, flash, Hexs, point, LES, seg_an, seg_sout)
/* synthesis syn_black_box black_box_pad_pin="clk,rst,SW0,flash,Hexs[31:0],point[7:0],LES[7:0],seg_an[7:0],seg_sout[7:0]" */;
  input clk;
  input rst;
  input SW0;
  input flash;
  input [31:0]Hexs;
  input [7:0]point;
  input [7:0]LES;
  output [7:0]seg_an;
  output [7:0]seg_sout;
endmodule