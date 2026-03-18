//数据存储器访问控制器，处理字节/半字/字对齐读写
module dm_controller(mem_w, Addr_in, Data_write, dm_ctrl, 
  Data_read_from_dm, Data_read, Data_write_to_dm, wea_mem)
/* synthesis syn_black_box black_box_pad_pin="mem_w,Addr_in[31:0],Data_write[31:0],dm_ctrl[2:0],Data_read_from_dm[31:0],Data_read[31:0],Data_write_to_dm[31:0],wea_mem[3:0]" */;
  input mem_w;
  input [31:0]Addr_in;
  input [31:0]Data_write;
  input [2:0]dm_ctrl;
  input [31:0]Data_read_from_dm;
  output [31:0]Data_read;
  output [31:0]Data_write_to_dm;
  output [3:0]wea_mem;
endmodule