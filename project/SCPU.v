//单周期CPU核心（黑盒IP），执行指令、输出PC/地址/数据/写信号
module SCPU(clk, reset, MIO_ready, inst_in, Data_in, mem_w, 
  PC_out, Addr_out, Data_out, dm_ctrl, CPU_MIO, INT)
/* synthesis syn_black_box black_box_pad_pin="clk,reset,MIO_ready,inst_in[31:0],Data_in[31:0],mem_w,PC_out[31:0],Addr_out[31:0],Data_out[31:0],dm_ctrl[2:0],CPU_MIO,INT" */;
  input clk;
  input reset;
  input MIO_ready;
  input [31:0]inst_in;
  input [31:0]Data_in;
  output mem_w;
  output [31:0]PC_out;
  output [31:0]Addr_out;
  output [31:0]Data_out;
  output [2:0]dm_ctrl;
  output CPU_MIO;
  input INT;
endmodule