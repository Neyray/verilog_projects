`timescale 1ns / 1ps
// ============================================================
// 单周期 RISC-V CPU (RV32I 子集)
// 
// dm_ctrl[2:0] = funct3[2:0]，与 mem_w 共同描述访存类型：
//   mem_w=0, dm_ctrl=010 → lw
//   mem_w=0, dm_ctrl=001 → lh  (有符号扩展)
//   mem_w=0, dm_ctrl=000 → lb  (有符号扩展)
//   mem_w=0, dm_ctrl=101 → lhu (无符号扩展)
//   mem_w=0, dm_ctrl=100 → lbu (无符号扩展)
//   mem_w=1, dm_ctrl=010 → sw
//   mem_w=1, dm_ctrl=001 → sh
//   mem_w=1, dm_ctrl=000 → sb
// ============================================================
module SCPU(
    input         clk,
    input         reset,       // 高电平复位
    input         MIO_ready,   // 总线就绪（简单系统接 1）
    input  [31:0] inst_in,     // 从指令 ROM 来的指令
    input  [31:0] Data_in,     // 从总线/内存读回的数据
    output        mem_w,       // 写使能（1=store）
    output [31:0] PC_out,      // 当前 PC
    output [31:0] Addr_out,    // 访存地址 / ALU 结果
    output [31:0] Data_out,    // 写出数据（rs2）
    output [2:0]  dm_ctrl,     // 访存控制 = funct3
    output        CPU_MIO,     // 正在访问 MIO（load 或 store）
    input         INT          // 中断（本设计不处理，忽略）
);

    // ----------------------------------------------------------------
    // PC 寄存器
    // ----------------------------------------------------------------
    reg  [31:0] PC;
    wire [31:0] PC_next;
    assign PC_out = PC;

    always @(posedge clk or posedge reset) begin
        if (reset)        PC <= 32'h0;
        else if (MIO_ready) PC <= PC_next;
    end

    // ----------------------------------------------------------------
    // 指令字段拆分
    // ----------------------------------------------------------------
    wire [6:0] opcode = inst_in[6:0];
    wire [4:0] rd     = inst_in[11:7];
    wire [2:0] funct3 = inst_in[14:12];
    wire [4:0] rs1    = inst_in[19:15];
    wire [4:0] rs2    = inst_in[24:20];
    wire [6:0] funct7 = inst_in[31:25];

    // ----------------------------------------------------------------
    // 立即数生成
    // ----------------------------------------------------------------
    wire [31:0] imm_I = {{20{inst_in[31]}}, inst_in[31:20]};
    wire [31:0] imm_S = {{20{inst_in[31]}}, inst_in[31:25], inst_in[11:7]};
    wire [31:0] imm_B = {{19{inst_in[31]}}, inst_in[31],
                          inst_in[7], inst_in[30:25], inst_in[11:8], 1'b0};
    wire [31:0] imm_U = {inst_in[31:12], 12'b0};
    wire [31:0] imm_J = {{11{inst_in[31]}}, inst_in[31], inst_in[19:12],
                          inst_in[20], inst_in[30:21], 1'b0};

    // ----------------------------------------------------------------
    // opcode 常量
    // ----------------------------------------------------------------
    localparam LUI    = 7'h37;
    localparam AUIPC  = 7'h17;
    localparam JAL    = 7'h6F;
    localparam JALR   = 7'h67;
    localparam BRANCH = 7'h63;
    localparam LOAD   = 7'h03;
    localparam STORE  = 7'h23;
    localparam ALUI   = 7'h13;
    localparam ALUR   = 7'h33;

    // ----------------------------------------------------------------
    // 类型判断
    // ----------------------------------------------------------------
    wire is_lui    = (opcode == LUI);
    wire is_auipc  = (opcode == AUIPC);
    wire is_jal    = (opcode == JAL);
    wire is_jalr   = (opcode == JALR);
    wire is_branch = (opcode == BRANCH);
    wire is_load   = (opcode == LOAD);
    wire is_store  = (opcode == STORE);
    wire is_alui   = (opcode == ALUI);
    wire is_alur   = (opcode == ALUR);

    // ----------------------------------------------------------------
    // 输出控制信号
    // ----------------------------------------------------------------
    assign mem_w   = is_store;
    assign CPU_MIO = is_load | is_store;
    assign dm_ctrl = funct3;   // funct3 完整携带访存类型

    // ----------------------------------------------------------------
    // 寄存器堆（32 × 32bit，x0 恒为 0）
    // ----------------------------------------------------------------
    reg [31:0] rf [0:31];
    wire [31:0] rs1_data = (rs1 == 0) ? 32'b0 : rf[rs1];
    wire [31:0] rs2_data = (rs2 == 0) ? 32'b0 : rf[rs2];

    // ----------------------------------------------------------------
    // ALU 输入选择
    // ----------------------------------------------------------------
    wire [31:0] alu_A =
        is_auipc             ? PC        :
        is_lui               ? 32'b0     :
                               rs1_data;

    wire [31:0] alu_B =
        (is_alur | is_branch) ? rs2_data :
        (is_lui | is_auipc)   ? imm_U    :
        is_store              ? imm_S    :
                                imm_I;

    wire [4:0] shamt = is_alur ? rs2_data[4:0] : inst_in[24:20];

    // ----------------------------------------------------------------
    // ALU 运算
    // ----------------------------------------------------------------
    reg [31:0] alu_out;
    always @(*) begin
        case (opcode)
            LUI, AUIPC:        alu_out = alu_A + alu_B;
            LOAD, STORE, JALR: alu_out = alu_A + alu_B;
            ALUI: case (funct3)
                3'b000: alu_out = alu_A + alu_B;
                3'b010: alu_out = ($signed(alu_A) < $signed(alu_B)) ? 32'd1 : 32'd0;
                3'b011: alu_out = (alu_A < alu_B) ? 32'd1 : 32'd0;
                3'b100: alu_out = alu_A ^ alu_B;
                3'b110: alu_out = alu_A | alu_B;
                3'b111: alu_out = alu_A & alu_B;
                3'b001: alu_out = alu_A << shamt;
                // ALUI 内部
                3'b101: begin
                    if (funct7[5])
                        alu_out = $signed(alu_A) >>> shamt; // 算术右移，独立上下文，强制保留符号
                    else
                        alu_out = alu_A >> shamt;           // 逻辑右移
                end
                default: alu_out = 32'b0;
            endcase
            ALUR: case (funct3)
                3'b000: alu_out = funct7[5] ? (alu_A - rs2_data) : (alu_A + rs2_data);
                3'b001: alu_out = alu_A << shamt;
                3'b010: alu_out = ($signed(alu_A) < $signed(rs2_data)) ? 32'd1 : 32'd0;
                3'b011: alu_out = (alu_A < rs2_data) ? 32'd1 : 32'd0;
                3'b100: alu_out = alu_A ^ rs2_data;
                // ALUR 内部
                3'b101: begin
                    if (funct7[5])
                        alu_out = $signed(alu_A) >>> shamt; 
                    else
                        alu_out = alu_A >> shamt;
                end
                3'b110: alu_out = alu_A | rs2_data;
                3'b111: alu_out = alu_A & rs2_data;
                default: alu_out = 32'b0;
            endcase
            default: alu_out = 32'b0;
        endcase
    end

    // ----------------------------------------------------------------
    // 分支条件判断
    // ----------------------------------------------------------------
    reg branch_taken;
    always @(*) begin
        case (funct3)
            3'b000: branch_taken = (rs1_data == rs2_data);
            3'b001: branch_taken = (rs1_data != rs2_data);
            3'b100: branch_taken = ($signed(rs1_data) < $signed(rs2_data));
            3'b101: branch_taken = ($signed(rs1_data) >= $signed(rs2_data));
            3'b110: branch_taken = (rs1_data < rs2_data);
            3'b111: branch_taken = (rs1_data >= rs2_data);
            default: branch_taken = 1'b0;
        endcase
    end

    // ----------------------------------------------------------------
    // 下一 PC
    // ----------------------------------------------------------------
    assign PC_next =
        is_jal                     ? (PC + imm_J) :
        is_jalr                    ? ((rs1_data + imm_I) & ~32'h1) :
        (is_branch & branch_taken) ? (PC + imm_B) :
        (PC + 32'd4);

    // ----------------------------------------------------------------
    // 外部输出
    // ----------------------------------------------------------------
    assign Addr_out = alu_out;
    assign Data_out = rs2_data;

    // ----------------------------------------------------------------
    // 写回数据选择
    // ----------------------------------------------------------------
    wire [31:0] wb_data =
        (is_lui | is_auipc)  ? alu_out      :
        (is_jal | is_jalr)   ? (PC + 32'd4) :
        is_load              ? Data_in       :
        (is_alui | is_alur)  ? alu_out       :
        32'b0;

    wire wb_en = is_lui | is_auipc | is_jal | is_jalr |
                 is_load | is_alui | is_alur;

    // ----------------------------------------------------------------
    // 寄存器写回（时钟上升沿）
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (!reset && wb_en && (rd != 5'b0) && MIO_ready)
            rf[rd] <= wb_data;
    end

endmodule
