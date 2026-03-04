module top(
    input clk,
    input rstn,
    input [15:0] sw_i,
    output [7:0] disp_seg_o,
    output [7:0] disp_an_o,
    output [15:0] led_o
);
    // --- 1. 时钟分频 ---
    reg [31:0] clkdiv;
    wire Clk_CPU;
    always @(posedge clk or negedge rstn) begin
        if(!rstn) clkdiv <= 0;
        else clkdiv <= clkdiv + 1'b1;
    end
    assign Clk_CPU = (sw_i[15]) ? clkdiv[27] : clkdiv[25];

    // --- 2. PC与指令存储器 ---
    reg [31:0] PC;
    wire [31:0] NPC;
    wire [31:0] instr;
    
    // PC更新
    always @(posedge Clk_CPU or negedge rstn) begin
        if (!rstn) PC <= 32'h0;
        else if (sw_i[1] == 1'b0) PC <= NPC;
        else PC <= PC;
    end
    
    // ROM (PC/4)
    dist_mem_im u_im ( .a(PC[7:2]), .spo(instr) );
    
    // --- 3. 译码与控制 ---
    wire [6:0] Op = instr[6:0];
    wire [6:0] Funct7 = instr[31:25];
    wire [2:0] Funct3 = instr[14:12];
    wire [4:0] rs1 = instr[19:15];
    wire [4:0] rs2 = instr[24:20];
    wire [4:0] rd = instr[11:7];
    
    wire RegWrite, MemWrite, ALUSrc;
    wire [2:0] EXTOp;
    wire [1:0] WDSel, NPCOp;
    wire [4:0] ALUOp;
    wire [2:0] DMType;
    wire i_beq, i_bne; // 来自Ctrl
    
    ctrl u_ctrl (
        .Op(Op), .Funct7(Funct7), .Funct3(Funct3),
        .RegWrite(RegWrite), .MemWrite(MemWrite), .EXTOp(EXTOp),
        .ALUOp(ALUOp), .ALUSrc(ALUSrc), .WDSel(WDSel), 
        .DMType(DMType), .NPCOp(NPCOp),
        .i_beq(i_beq), .i_bne(i_bne) // 连接
    );
    
    // --- 4. 立即数扩展 ---
    wire [31:0] immout;
    EXT u_ext ( .instr(instr), .EXTOp(EXTOp), .immout(immout) );
    
    // --- 5. 数据通路 (RF, ALU, DM) ---
    wire [31:0] RD1, RD2, C_alu, dout_dm, WD_rf;
    wire Zero; // ALU零标志
    
    RF u_rf(
        .clk(clk), .rst(~rstn),
        .RFWr(RegWrite), .sw_i(sw_i),
        .A1(rs1), .A2(rs2), .A3(rd),
        .WD(WD_rf), .RD1(RD1), .RD2(RD2)
    );
    
    // ALU B源选择
    wire [31:0] B_alu = (ALUSrc) ? immout : RD2;
    
    alu u_alu(
        .A(RD1), .B(B_alu), .ALUOp(ALUOp),
        .C(C_alu), .Zero(Zero)
    );
    
    dm u_dm (
        .clk(clk), .DMWr(MemWrite),
        .addr(C_alu), .din(RD2),
        .DMType(DMType), .dout(dout_dm)
    );
    
    // 写回数据选择
    assign WD_rf = (WDSel == 2'b01) ? dout_dm :
                   (WDSel == 2'b10) ? (PC + 4) : C_alu;
    
    // --- 6. NPC生成逻辑 (标准架构) ---
    // 使用 Controller 的指令信号 + ALU 的 Zero 信号
    wire branch_taken = (i_beq & Zero) | (i_bne & ~Zero);
    
    reg [31:0] npc_temp;
    always @(*) begin
        case(NPCOp)
            2'b00: npc_temp = PC + 4;                           // 顺序执行
            2'b01: npc_temp = (branch_taken) ? (PC + immout) : (PC + 4); // Branch
            2'b10: npc_temp = PC + immout;                      // JAL
            2'b11: npc_temp = (RD1 + immout) & ~32'd1;         // JALR
            default: npc_temp = PC + 4;
        endcase
    end
    assign NPC = npc_temp;
    
    // --- 7. 显示 ---
    assign led_o = C_alu[15:0];
    
    reg [63:0] display_data;
    always @(*) begin
        if (sw_i[14]) display_data = {32'h0, instr};
        else if (sw_i[12]) display_data = {32'h0, C_alu};
        else display_data = {32'h0, PC};
    end
    
    seg7x16 u_seg7x16(
        .clk(clk), .rstn(rstn), 
        .i_data(display_data), .disp_mode(sw_i[0]),
        .o_seg(disp_seg_o), .o_sel(disp_an_o)
    );
endmodule