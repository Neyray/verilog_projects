//`timescale 1ns / 1ps
module seg7x16(
    input clk,
    input rstn,
    input [31:0] i_data,
    output [7:0] o_seg,
    output [7:0] o_sel
);

    // 1) 分频 - 利用计数器cnt对clk分频得到seg7_clk
    reg [14:0] cnt;
    wire seg7_clk;
    
    always @(posedge clk, negedge rstn)
        if (!rstn)
            cnt <= 0;
        else
            cnt <= cnt + 1'b1;
    
    assign seg7_clk = cnt[14];

    // 2) 8选1 - seg7_addr作为8选1选择器的地址信号
    reg [2:0] seg7_addr;
    
    always @(posedge seg7_clk, negedge rstn)
        if (!rstn)
            seg7_addr <= 0;
        else
            seg7_addr <= seg7_addr + 1'b1;

    // 3) 输出选中数码管使能信号
    reg [7:0] o_sel_r;
    
    always @(*) 
        case(seg7_addr)
            3'd7: o_sel_r = 8'b01111111;
            3'd6: o_sel_r = 8'b10111111;
            3'd5: o_sel_r = 8'b11011111;
            3'd4: o_sel_r = 8'b11101111;
            3'd3: o_sel_r = 8'b11110111;
            3'd2: o_sel_r = 8'b11111011;
            3'd1: o_sel_r = 8'b11111101;
            3'd0: o_sel_r = 8'b11111110;
        endcase

    // 4) 8个数码管显示数字串 - 存储输入数据
    reg [31:0] i_data_store;
    
    always @(posedge clk, negedge rstn)
        if (!rstn)
            i_data_store <= 0;
        else
            i_data_store <= i_data;

    // 当前一个数码管要显示的数串
    reg [3:0] seg_data_r;
    
    always @(*)
        case(seg7_addr)
            3'd0: seg_data_r = i_data_store[3:0];
            3'd1: seg_data_r = i_data_store[7:4];
            3'd2: seg_data_r = i_data_store[11:8];
            3'd3: seg_data_r = i_data_store[15:12];
            3'd4: seg_data_r = i_data_store[19:16];
            3'd5: seg_data_r = i_data_store[23:20];
            3'd6: seg_data_r = i_data_store[27:24];
            3'd7: seg_data_r = i_data_store[31:28];
        endcase

    // 5) 要显示数字的7段码
    reg [7:0] o_seg_r;
    
    always @(posedge clk, negedge rstn)
        if (!rstn)
            o_seg_r <= 8'hff;
        else
            case(seg_data_r)
                4'h0: o_seg_r <= 8'hC0;
                4'h1: o_seg_r <= 8'hF9;
                4'h2: o_seg_r <= 8'hA4;
                4'h3: o_seg_r <= 8'hB0;
                4'h4: o_seg_r <= 8'h99;
                4'h5: o_seg_r <= 8'h92;
                4'h6: o_seg_r <= 8'h82;
                4'h7: o_seg_r <= 8'hF8;
                4'h8: o_seg_r <= 8'h80;
                4'h9: o_seg_r <= 8'h90;
                4'hA: o_seg_r <= 8'h88;
                4'hB: o_seg_r <= 8'h83;
                4'hC: o_seg_r <= 8'hC6;
                4'hD: o_seg_r <= 8'hA1;
                4'hE: o_seg_r <= 8'h86;
                4'hF: o_seg_r <= 8'h8E;
            endcase

    assign o_sel = o_sel_r;
    assign o_seg = o_seg_r;

endmodule