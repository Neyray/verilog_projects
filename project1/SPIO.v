//简单并行IO外设，控制LED输出，解析counter_set信号
module SPIO(clk, rst, EN, P_Data, counter_set, LED_out, led, 
  GPIOf0)
/* synthesis syn_black_box black_box_pad_pin="clk,rst,EN,P_Data[31:0],counter_set[1:0],LED_out[15:0],led[15:0],GPIOf0[13:0]" */;
  input clk;
  input rst;
  input EN;
  input [31:0]P_Data;
  output [1:0]counter_set;
  output [15:0]LED_out;
  output [15:0]led;
  output [13:0]GPIOf0;
endmodule