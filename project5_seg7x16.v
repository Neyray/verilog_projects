module seg7x16(
    input clk,          // 系统主时钟 (通常为 50MHz 或 100MHz)
    input rstn,         // 异步低电平复位信号 (低电平有效)
    input disp_mode,    // 显示模式选择信号 (0: 译码模式, 1: 穿透模式/直接显示)
    input [63:0] i_data, // 待显示的 64 位数据 (8 个 8 位数码管数据)
    output [7:0] o_seg, // 7段数码管的段选线输出 (a, b, c, d, e, f, g, dp)
    output [7:0] o_sel  // 8位共阴/共阳数码管的位选线输出 (激活哪个数码管)
    );

    // --- 1) 扫描时钟分频 ---
    reg [14:0] cnt;    // 分频计数器
    wire seg7_clk;     // 数码管扫描时钟 (低频，通常几百 Hz 到几 kHz)
    
    // 时序逻辑：分频计数
    always @(posedge clk, negedge rstn) begin
        if (!rstn)
            cnt <= 0;
        else
            cnt <= cnt + 1'b1;
    end
    
    // 输出扫描时钟：使用计数器的第 14 位，实现 clk / 2^15 的分频
    assign seg7_clk = cnt[14]; 

    // --- 2) 数码管位选地址生成 (8选1) ---
    reg [2:0] seg7_addr; // 当前被选中的数码管地址 (0 到 7)
    
    // 时序逻辑：在扫描时钟 seg7_clk 的上升沿递增地址
    always @(posedge seg7_clk, negedge rstn) begin
        if(!rstn)
            seg7_addr <= 0;
        else
            seg7_addr <= seg7_addr + 1'b1;
    end
      
    // --- 3) 位选信号生成 (o_sel) ---
    reg [7:0] o_sel_r; // 位选信号的寄存器版本
    
    // 组合逻辑：根据当前地址 seg7_addr 确定哪个数码管被使能 (一位有效)
    always @(*) begin
        case (seg7_addr)
            7 : o_sel_r = 8'b01111111; // 选中第 7 位 (最高位)
            6 : o_sel_r = 8'b10111111;
            5 : o_sel_r = 8'b11011111;
            4 : o_sel_r = 8'b11101111;
            3 : o_sel_r = 8'b11110111;
            2 : o_sel_r = 8'b11111011;
            1 : o_sel_r = 8'b11111101;
            0 : o_sel_r = 8'b11111110; // 选中第 0 位 (最低位)
        endcase
    end
    
    // --- 4) 数据选择逻辑 (根据地址选择当前数码管的数据) ---
    reg [63:0] i_data_store; // 将输入数据 i_data 寄存器化存储
    
    // 时序逻辑：在主时钟 clk 上锁存输入数据 i_data
    always @(posedge clk, negedge rstn ) begin
        if(!rstn)
            i_data_store <= 0;
        else
            i_data_store <= i_data;
    end

    reg [7:0] seg_data_r; // 当前数码管要显示的 8 位数据 (来自 i_data_store)
    
    // 组合逻辑：根据 disp_mode 和 seg7_addr 选择数据
    always @(*) begin
        if(disp_mode==1'b0)begin // Hex 译码模式 (通常只看 32 位数据，每位 4 bits)
            case(seg7_addr)
                // 从 i_data_store 的低 32 位中提取 4 bits 数据 (高 4 位为 0)
                0 : seg_data_r = i_data_store[3:0];
                1 : seg_data_r = i_data_store[7:4];
                2 : seg_data_r = i_data_store[11:8];
                3 : seg_data_r = i_data_store[15:12];
                4 : seg_data_r = i_data_store[19:16];
                5 : seg_data_r = i_data_store[23:20];
                6 : seg_data_r = i_data_store[27:24];
                7 : seg_data_r = i_data_store[31:28];
            endcase end
        else begin // 穿透/跑马灯模式 (使用 64 位数据，每位 8 bits)
            case(seg7_addr)
                // 从 i_data_store 的 64 位中提取 8 bits 数据
                0 : seg_data_r = i_data_store[7:0];
                1 : seg_data_r = i_data_store[15:8];
                2 : seg_data_r = i_data_store[23:16];
                3 : seg_data_r = i_data_store[31:24];
                4 : seg_data_r = i_data_store[39:32];
                5 : seg_data_r = i_data_store[47:40];
                6 : seg_data_r = i_data_store[55:48];
                7 : seg_data_r = i_data_store[63:56];
            endcase end
    end
    
    // --- 5) 7段码译码或直接输出 ---
    reg [7:0] o_seg_r; // 段选信号的寄存器版本
    
    // 时序逻辑：进行 Hex 译码并寄存器化输出
    always @(posedge clk, negedge rstn) begin
        if(!rstn)
            o_seg_r <= 8'hff; // 复位时全灭
        else if(disp_mode==1'b0)begin // Hex 译码模式
            // 将 seg_data_r 的低 4 位（0-F）译码成 7 段码
            case(seg_data_r[3:0]) // 注意这里使用了 seg_data_r[3:0]
                4'h0 : o_seg_r <= 8'hC0;
                4'h1 : o_seg_r <= 8'hF9;
                4'h2 : o_seg_r <= 8'hA4;
                4'h3 : o_seg_r <= 8'hB0;
                4'h4 : o_seg_r <= 8'h99;
                4'h5 : o_seg_r <= 8'h92;
                4'h6 : o_seg_r <= 8'h82;
                4'h7 : o_seg_r <= 8'hF8;
                4'h8 : o_seg_r <= 8'h80;
                4'h9 : o_seg_r <= 8'h90;
                4'hA : o_seg_r <= 8'h88;
                4'hB : o_seg_r <= 8'h83;
                4'hC : o_seg_r <= 8'hC6;
                4'hD : o_seg_r <= 8'hA1;
                4'hE : o_seg_r <= 8'h86;
                4'hF : o_seg_r <= 8'h8E;
                default :o_seg_r<=8'hFF; 
            endcase end
        else begin 
           
            o_seg_r<=seg_data_r;
        end
    end
   
    assign o_sel = o_sel_r;
    assign o_seg = o_seg_r;

endmodule