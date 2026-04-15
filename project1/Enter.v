`timescale 1ns / 1ps

//输入预处理，直通按键/开关（预留防抖位置）

module   Enter(input clk,
                input[4:0] BTN,	 // 五个按键
                input[15:0] SW, // �??�??
                output[4:0] BTN_out,
                output[15:0] SW_out // �??�??
            );
	// TODO 防抖

    // always @(*) begin
    //     BTN_out = BTN;
    //     SW_out = SW;
    // end
	
    assign BTN_out = BTN;
    assign SW_out = SW;

endmodule