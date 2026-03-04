//
// 第七讲: 顶层模块 (修改自 project5_RF_ALU_top.v)
//
`define ALUOp_add 5'b00011
`define ALUOp_sub 5'b00100

module top(
    input clk,
    input rstn,
    input [15:0]sw_i,
    // (其他按键输入未在第7讲使用)
    // input CPU_RESETN, 
    // input BTNC,BTNU,BTNL,BTNR,BTND,
    output [7:0]disp_seg_o,
    output [7:0]disp_an_o,
    output [15:0]led_o
);

    // --- 1. 时钟分频 (与之前相同) ---
    reg [31:0] clkdiv;
    wire Clk_CPU;
    always @(posedge clk or negedge rstn) begin
        if(!rstn) clkdiv <= 0;
        else clkdiv <= clkdiv + 1'b1;
    end
    assign Clk_CPU = (sw_i[15]) ? clkdiv[27] : clkdiv[25]; // [cite: 424]


    // --- 2. PC 和 指令ROM ---
    reg [5:0] rom_addr; // PC (Program Counter), 6位地址
    wire [31:0] instr;  // 指令

    // PC 逻辑
    always @(posedge Clk_CPU or negedge rstn) begin
        if (!rstn)
            rom_addr <= 6'h0;
        else if (sw_i[1] == 1'b0) // 正常模式 (非调试) 
            rom_addr <= rom_addr + 1; // 串行, PC+1
        else
            rom_addr <= rom_addr; // 调试模式, PC保持 
    end

    // 实例化 指令ROM (IM)
    // (您需要按照第3讲的方法, 用IP核生成一个ROM, [cite: 387]
    //  并加载下面的 'Test_8_Instr1.coe' 文件)
    dist_mem_im u_im (
        .a(rom_addr[5:0]), // 地址输入
        .spo(instr)      // 指令输出
    );


    // --- 3. 译码 ---
    wire [6:0] Op     = instr[6:0];     // [cite: 549]
    wire [6:0] Funct7 = instr[31:25];  // [cite: 550]
    wire [2:0] Funct3 = instr[14:12];  // [cite: 551]
    wire [4:0] rs1    = instr[19:15];  // [cite: 552]
    wire [4:0] rs2    = instr[24:20];  // [cite: 553]
    wire [4:0] rd     = instr[11:7];   // [cite: 554]


    // --- 4. 实例化 Ctrl 和 EXT 模块 ---
    wire RegWrite, MemWrite, ALUSrc;
    wire [1:0] EXTOp, WDSel;
    wire [4:0] ALUOp_ctrl; // 来自Ctrl的ALUOp
    wire [2:0] DMType;
    wire [31:0] immout;

    ctrl u_ctrl (
        .Op(Op), .Funct7(Funct7), .Funct3(Funct3),
        .RegWrite(RegWrite), .MemWrite(MemWrite), .EXTOp(EXTOp),
        .ALUOp(ALUOp_ctrl), .ALUSrc(ALUSrc), .DMType(DMType), .WDSel(WDSel)
    );

    EXT u_ext (
        .instr(instr), .EXTOp(EXTOp), .immout(immout)
    );


    // --- 5. 实例化 RF, ALU, DM (数据通路) ---
    wire [31:0] RD1, RD2; // RF读数据
    wire [31:0] C_alu;   // ALU计算结果
    wire [31:0] dout_dm; // DM读数据
    wire [31:0] B_alu;   // ALU的B输入
    wire [31:0] WD_rf;   // RF的写数据

    // RF (寄存器堆)
    // 注意: A1, A2, A3, WD 的来源已改变!
    RF u_rf(
        .clk(clk),
        .rst(~rstn), // RF模块用高电平复位
        .RFWr(RegWrite),  // <== 来自 Ctrl
        .sw_i(sw_i),      // sw_i[1] 调试模式 [cite: 444]
        .A1(rs1),         // <== 来自 译码
        .A2(rs2),         // <== 来自 译码
        .A3(rd),          // <== 来自 译码
        .WD(WD_rf),       // <== 来自 MUX
        .RD1(RD1),
        .RD2(RD2)
    );

    // MUX: ALU B源 [cite: 648]
    assign B_alu = (ALUSrc) ? immout : RD2;

    // ALU (算术逻辑单元)
    alu u_alu(
        .A(RD1),          // 来自 RF.RD1
        .B(B_alu),        // <== 来自 MUX
        .ALUOp(ALUOp_ctrl), // <== 来自 Ctrl
        .C(C_alu),
        .Zero()           // (Zero标志在第7讲暂未用到)
    );

    // DM (数据存储器)
    dm u_dm (
        .clk(clk),
        .DMWr(MemWrite),    // <== 来自 Ctrl
        .addr(C_alu),       // 地址来自 ALU 结果 (rs1 + imm)
        .din(RD2),          // 写入数据来自 RF.RD2 (sw x1, 0(x2))
        .DMType(DMType),    // <== 来自 Ctrl
        .dout(dout_dm)
    );
    
    // MUX: RF 写数据源 [cite: 652-654]
    // WDSel 01 (Load)  -> 来自 DM
    // WDSel 00 (R/I-type) -> 来自 ALU
    assign WD_rf = (WDSel[0]) ? dout_dm : C_alu;


    // --- 6. 显示逻辑 (用于调试) ---
    reg [63:0] display_data;
    reg [5:0]  reg_addr; // 用于RF循环显示
    
    // RF循环显示计数器
    always @(posedge Clk_CPU or negedge rstn) begin
        if (!rstn)
            reg_addr <= 6'd0;
        else if (sw_i[13] == 1'b1) begin // S[13]显示RF [cite: 424]
            if (reg_addr >= 6'd32) // 0-31 + 1个分隔符
                reg_addr <= 6'd0;
            else
                reg_addr <= reg_addr + 1;
        end
        else
            reg_addr <= 6'd0;
    end

    // 选择显示的数据 (类似 project3_sccomp) [cite: 45]
    always @(*) begin
        if (sw_i[0] == 1'b1) begin // 模式1: 跑马灯
            display_data = 64'h0; // (第7讲不使用跑马灯)
        end
        else begin // 模式0: 调试数据显示 [cite: 424]
            case (1'b1)
                sw_i[14]: // 显示ROM (指令)
                    display_data = {32'h0, instr};
                sw_i[13]: // 显示RF (寄存器)
                    if(reg_addr < 32)
                        display_data = {32'h0, u_rf.rf[reg_addr]}; // 窥探RF内部
                    else
                        display_data = 64'hFFFFFFFFFFFFFFFF; // 分隔符
                sw_i[12]: // 显示ALU (结果)
                    display_data = {32'h0, C_alu};
                sw_i[11]: // 显示DM (内容)
                    display_data = {32'h0, dout_dm}; // (注: DM读地址是ALU结果,可能不直观)
                default: // 默认显示指令
                    display_data = {32'h0, instr};
            endcase
        end
    end

    // LED显示ALU结果
    assign led_o = C_alu[15:0];

    // 数码管驱动
    seg7x16 u_seg7x16(
        .clk(clk),
        .rstn(rstn),
        .i_data(display_data),
        .disp_mode(sw_i[0]), // sw[0]=0, 文本模式 [cite: 328]
        .o_seg(disp_seg_o),
        .o_sel(disp_an_o)
    );

endmodule