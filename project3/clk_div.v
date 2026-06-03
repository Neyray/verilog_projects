`timescale 1ns / 1ps
//时钟分频，产生32位计数器clkdiv和CPU时钟Clk_CPU（SW2控制快/慢速）
module clk_div(input clk,
					input rst,
					input SW2,
					output reg[31:0]clkdiv,
					output Clk_CPU
					);
					
// Clock divider

	localparam FAST_CPU_CLKDIV_BIT = 3;   // 约 6.25MHz，LED/提示显示肉眼可跟
	localparam SLOW_CPU_CLKDIV_BIT = 24;  // 约 3Hz，便于验收时观察 PC/指令

	always @ (posedge clk or posedge rst) begin 
		if (rst) clkdiv <= 0; else clkdiv <= clkdiv + 1'b1; end
		
	assign Clk_CPU=(SW2)? clkdiv[SLOW_CPU_CLKDIV_BIT] : clkdiv[FAST_CPU_CLKDIV_BIT];
		
endmodule
