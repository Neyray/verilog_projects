`timescale 1ns / 1ps
// ============================================================
// 五级流水线 RISC-V CPU (RV32I 子集)
// 
// 流水线阶段: IF → ID → EX → MEM → WB
//
// 冒险处理:
//   1. 数据冒险: EX/MEM 和 MEM/WB 前递 (Forwarding)
//   2. Load-Use 冒险: 插入1拍气泡 (Stall)
//   3. 控制冒险: 分支/跳转在 EX 阶段判断，冲刷 IF/ID 和 ID/EX (Flush 2条)
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
module PCPU(
    input         clk,
    input         reset,       // 高电平复位
    input         MIO_ready,   // 总线就绪（简单系统接 1）
    input  [31:0] inst_in,     // 从指令 ROM 来的指令（IF 阶段）
    input  [31:0] Data_in,     // 从总线/内存读回的数据（MEM 阶段）
    output        mem_w,       // 写使能（1=store），从 MEM 阶段输出
    output [31:0] PC_out,      // 当前 PC（IF 阶段）
    output [31:0] Addr_out,    // 访存地址 / ALU 结果，从 MEM 阶段输出
    output [31:0] Data_out,    // 写出数据（rs2），从 MEM 阶段输出
    output [2:0]  dm_ctrl,     // 访存控制 = funct3，从 MEM 阶段输出
    output        CPU_MIO,     // 正在访问 MIO（load 或 store）
    input         INT          // 中断（本设计不处理，忽略）
);

    // ================================================================
    // NOP 指令编码: addi x0, x0, 0 = 0x00000013
    // ================================================================
    localparam NOP = 32'h00000013;

    // ================================================================
    // opcode 常量 (与单周期版相同)
    // ================================================================
    localparam LUI    = 7'h37;
    localparam AUIPC  = 7'h17;
    localparam JAL    = 7'h6F;
    localparam JALR   = 7'h67;
    localparam BRANCH = 7'h63;
    localparam LOAD   = 7'h03;
    localparam STORE  = 7'h23;
    localparam ALUI   = 7'h13;
    localparam ALUR   = 7'h33;

    // ================================================================
    //  寄存器堆（32 × 32bit，x0 恒为 0）
    //  WB 阶段写，ID 阶段读
    // ================================================================
    reg [31:0] rf [0:31];

    // --- 前向声明：ID/EX 前递和 WB->ID 同拍读写旁路共用 ---
    wire [31:0] ex_mem_wb_data;
    wire [31:0] wb_data;
    reg [4:0]  EX_MEM_rd;
    reg        EX_MEM_wb_en;
    reg [4:0]  MEM_WB_rd;
    reg        MEM_WB_wb_en;

    // ================================================================
    //                    ★ IF 阶段 ★
    // ================================================================
    reg  [31:0] PC;
    assign PC_out = PC;

    // --- 前向声明冒险控制信号（后面会赋值） ---
    wire        stall;          // load-use 停顿
    wire        flush;          // 分支/跳转冲刷
    wire [31:0] branch_target;  // 跳转目标地址

    // PC 更新
    always @(posedge clk or posedge reset) begin
        if (reset)
            PC <= 32'h0;
        else if (stall)
            PC <= PC;               // load-use 暂停，PC 不动
        else if (flush)
            PC <= branch_target;    // 跳转/分支taken，跳到目标
        else
            PC <= PC + 32'd4;       // 正常顺序执行
    end

    // ================================================================
    //              ★ IF/ID 流水线寄存器 ★
    // ================================================================
    reg [31:0] IF_ID_inst;
    reg [31:0] IF_ID_PC;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            IF_ID_inst <= NOP;
            IF_ID_PC   <= 32'h0;
        end else if (stall) begin
            // load-use 停顿：保持不变
            IF_ID_inst <= IF_ID_inst;
            IF_ID_PC   <= IF_ID_PC;
        end else if (flush) begin
            // 分支冲刷：插入气泡
            IF_ID_inst <= NOP;
            IF_ID_PC   <= 32'h0;
        end else begin
            IF_ID_inst <= inst_in;
            IF_ID_PC   <= PC;
        end
    end

    // ================================================================
    //                    ★ ID 阶段 ★
    //  从 IF/ID 寄存器取指令，进行译码 + 读寄存器堆
    // ================================================================

    // --- 指令字段拆分 ---
    wire [6:0] id_opcode = IF_ID_inst[6:0];
    wire [4:0] id_rd     = IF_ID_inst[11:7];
    wire [2:0] id_funct3 = IF_ID_inst[14:12];
    wire [4:0] id_rs1    = IF_ID_inst[19:15];
    wire [4:0] id_rs2    = IF_ID_inst[24:20];
    wire [6:0] id_funct7 = IF_ID_inst[31:25];

    // --- 类型判断 ---
    wire id_is_lui    = (id_opcode == LUI);
    wire id_is_auipc  = (id_opcode == AUIPC);
    wire id_is_jal    = (id_opcode == JAL);
    wire id_is_jalr   = (id_opcode == JALR);
    wire id_is_branch = (id_opcode == BRANCH);
    wire id_is_load   = (id_opcode == LOAD);
    wire id_is_store  = (id_opcode == STORE);
    wire id_is_alui   = (id_opcode == ALUI);
    wire id_is_alur   = (id_opcode == ALUR);

    // --- 立即数生成 ---
    wire [31:0] id_imm_I = {{20{IF_ID_inst[31]}}, IF_ID_inst[31:20]};
    wire [31:0] id_imm_S = {{20{IF_ID_inst[31]}}, IF_ID_inst[31:25], IF_ID_inst[11:7]};
    wire [31:0] id_imm_B = {{19{IF_ID_inst[31]}}, IF_ID_inst[31],
                             IF_ID_inst[7], IF_ID_inst[30:25], IF_ID_inst[11:8], 1'b0};
    wire [31:0] id_imm_U = {IF_ID_inst[31:12], 12'b0};
    wire [31:0] id_imm_J = {{11{IF_ID_inst[31]}}, IF_ID_inst[31], IF_ID_inst[19:12],
                             IF_ID_inst[20], IF_ID_inst[30:21], 1'b0};

    // --- 选择立即数 ---
    wire [31:0] id_imm =
        (id_is_lui | id_is_auipc) ? id_imm_U :
        id_is_jal                 ? id_imm_J :
        id_is_branch              ? id_imm_B :
        id_is_store               ? id_imm_S :
                                    id_imm_I;  // LOAD, ALUI, JALR

    // --- 读寄存器堆 ---
    wire [31:0] id_rs1_raw = (id_rs1 == 5'b0) ? 32'b0 : rf[id_rs1];
    wire [31:0] id_rs2_raw = (id_rs2 == 5'b0) ? 32'b0 : rf[id_rs2];

    // WB 和 ID 同拍发生时，寄存器堆组合读会先看到旧值。
    // 这里把当前 WB 阶段的数据直接旁路到 ID，修复间隔 3 条指令的 RAW 依赖。
    wire wb_to_id_rs1 = MEM_WB_wb_en && (MEM_WB_rd != 5'b0) && (MEM_WB_rd == id_rs1);
    wire wb_to_id_rs2 = MEM_WB_wb_en && (MEM_WB_rd != 5'b0) && (MEM_WB_rd == id_rs2);

    wire [31:0] id_rs1_data = wb_to_id_rs1 ? wb_data : id_rs1_raw;
    wire [31:0] id_rs2_data = wb_to_id_rs2 ? wb_data : id_rs2_raw;

    // --- 写回使能 ---
    wire id_wb_en = id_is_lui | id_is_auipc | id_is_jal | id_is_jalr |
                    id_is_load | id_is_alui | id_is_alur;

    // --- 写存储器使能 ---
    wire id_mem_w = id_is_store;

    // ================================================================
    //              ★ ID/EX 流水线寄存器 ★
    // ================================================================
    reg [31:0] ID_EX_PC;
    reg [31:0] ID_EX_rs1_data, ID_EX_rs2_data;
    reg [31:0] ID_EX_imm;
    reg [4:0]  ID_EX_rd, ID_EX_rs1, ID_EX_rs2;
    reg [6:0]  ID_EX_opcode;
    reg [2:0]  ID_EX_funct3;
    reg [6:0]  ID_EX_funct7;
    reg        ID_EX_mem_w;
    reg        ID_EX_wb_en;
    reg        ID_EX_is_load, ID_EX_is_store;
    reg        ID_EX_is_branch;
    reg        ID_EX_is_jal, ID_EX_is_jalr;
    reg        ID_EX_is_lui, ID_EX_is_auipc;
    reg        ID_EX_is_alui, ID_EX_is_alur;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            // 1. 纯异步复位
            ID_EX_PC        <= 32'h0;
            ID_EX_rs1_data  <= 32'h0;
            ID_EX_rs2_data  <= 32'h0;
            ID_EX_imm       <= 32'h0;
            ID_EX_rd        <= 5'h0;
            ID_EX_rs1       <= 5'h0;
            ID_EX_rs2       <= 5'h0;
            ID_EX_opcode    <= 7'h13; // NOP
            ID_EX_funct3    <= 3'h0;
            ID_EX_funct7    <= 7'h0;
            ID_EX_mem_w     <= 1'b0;
            ID_EX_wb_en     <= 1'b0;
            ID_EX_is_load   <= 1'b0;
            ID_EX_is_store  <= 1'b0;
            ID_EX_is_branch <= 1'b0;
            ID_EX_is_jal    <= 1'b0;
            ID_EX_is_jalr   <= 1'b0;
            ID_EX_is_lui    <= 1'b0;
            ID_EX_is_auipc  <= 1'b0;
            ID_EX_is_alui   <= 1'b0;
            ID_EX_is_alur   <= 1'b0;
        end else if (flush || stall) begin
            // 2. 同步冲刷 / load-use停顿 → 插入气泡 (NOP)
            ID_EX_PC        <= 32'h0;
            ID_EX_rs1_data  <= 32'h0;
            ID_EX_rs2_data  <= 32'h0;
            ID_EX_imm       <= 32'h0;
            ID_EX_rd        <= 5'h0;
            ID_EX_rs1       <= 5'h0;
            ID_EX_rs2       <= 5'h0;
            ID_EX_opcode    <= 7'h13; // NOP
            ID_EX_funct3    <= 3'h0;
            ID_EX_funct7    <= 7'h0;
            ID_EX_mem_w     <= 1'b0;
            ID_EX_wb_en     <= 1'b0;
            ID_EX_is_load   <= 1'b0;
            ID_EX_is_store  <= 1'b0;
            ID_EX_is_branch <= 1'b0;
            ID_EX_is_jal    <= 1'b0;
            ID_EX_is_jalr   <= 1'b0;
            ID_EX_is_lui    <= 1'b0;
            ID_EX_is_auipc  <= 1'b0;
            ID_EX_is_alui   <= 1'b0;
            ID_EX_is_alur   <= 1'b0;
        end else begin
            // 3. 正常流水线传递
            ID_EX_PC        <= IF_ID_PC;
            ID_EX_rs1_data  <= id_rs1_data;
            ID_EX_rs2_data  <= id_rs2_data;
            ID_EX_imm       <= id_imm;
            ID_EX_rd        <= id_rd;
            ID_EX_rs1       <= id_rs1;
            ID_EX_rs2       <= id_rs2;
            ID_EX_opcode    <= id_opcode;
            ID_EX_funct3    <= id_funct3;
            ID_EX_funct7    <= id_funct7;
            ID_EX_mem_w     <= id_mem_w;
            ID_EX_wb_en     <= id_wb_en;
            ID_EX_is_load   <= id_is_load;
            ID_EX_is_store  <= id_is_store;
            ID_EX_is_branch <= id_is_branch;
            ID_EX_is_jal    <= id_is_jal;
            ID_EX_is_jalr   <= id_is_jalr;
            ID_EX_is_lui    <= id_is_lui;
            ID_EX_is_auipc  <= id_is_auipc;
            ID_EX_is_alui   <= id_is_alui;
            ID_EX_is_alur   <= id_is_alur;
        end
    end

    // ================================================================
    //                    ★ EX 阶段 ★
    //  ALU 运算 + 分支判断 + 前递 (Forwarding)
    // ================================================================

    // ================================================================
    //  前递逻辑 (Forwarding Unit)
    //
    //  优先级: EX/MEM > MEM/WB（更新的值优先）
    //  前递条件: 目标寄存器不为 x0，且寄存器号匹配
    // ================================================================
    wire fwd_ex_mem_rs1 = EX_MEM_wb_en && (EX_MEM_rd != 5'b0) && (EX_MEM_rd == ID_EX_rs1);
    wire fwd_ex_mem_rs2 = EX_MEM_wb_en && (EX_MEM_rd != 5'b0) && (EX_MEM_rd == ID_EX_rs2);
    wire fwd_mem_wb_rs1 = MEM_WB_wb_en && (MEM_WB_rd != 5'b0) && (MEM_WB_rd == ID_EX_rs1);
    wire fwd_mem_wb_rs2 = MEM_WB_wb_en && (MEM_WB_rd != 5'b0) && (MEM_WB_rd == ID_EX_rs2);

    wire [31:0] ex_rs1_data =
        fwd_ex_mem_rs1 ? ex_mem_wb_data :   // EX/MEM 优先（更新）
        fwd_mem_wb_rs1 ? wb_data        :     // 次选 MEM/WB
                         ID_EX_rs1_data;     // 无冒险，用寄存器堆值

    wire [31:0] ex_rs2_data =
        fwd_ex_mem_rs2 ? ex_mem_wb_data :
        fwd_mem_wb_rs2 ? wb_data        :
                         ID_EX_rs2_data;

    // --- ALU 输入选择（与单周期逻辑一致，但用前递后的数据） ---
    wire [31:0] alu_A =
        ID_EX_is_auipc ? ID_EX_PC   :
        ID_EX_is_lui   ? 32'b0      :
                         ex_rs1_data;

    wire [31:0] alu_B =
        (ID_EX_is_alur | ID_EX_is_branch) ? ex_rs2_data :
        (ID_EX_is_lui  | ID_EX_is_auipc)  ? ID_EX_imm   :
        ID_EX_is_store                     ? ID_EX_imm   :
                                             ID_EX_imm;   // LOAD, ALUI, JALR

    wire [4:0] shamt = ID_EX_is_alur ? ex_rs2_data[4:0] : ID_EX_imm[4:0];

    // --- ALU 运算 ---
    reg [31:0] alu_out;
    always @(*) begin
        case (ID_EX_opcode)
            LUI, AUIPC:        alu_out = alu_A + alu_B;
            LOAD, STORE, JALR: alu_out = alu_A + alu_B;
            ALUI: case (ID_EX_funct3)
                3'b000: alu_out = alu_A + alu_B;
                3'b010: alu_out = ($signed(alu_A) < $signed(alu_B)) ? 32'd1 : 32'd0;
                3'b011: alu_out = (alu_A < alu_B) ? 32'd1 : 32'd0;
                3'b100: alu_out = alu_A ^ alu_B;
                3'b110: alu_out = alu_A | alu_B;
                3'b111: alu_out = alu_A & alu_B;
                3'b001: alu_out = alu_A << shamt;
                3'b101: begin
                    if (ID_EX_funct7[5])
                        alu_out = $signed(alu_A) >>> shamt;
                    else
                        alu_out = alu_A >> shamt;
                end
                default: alu_out = 32'b0;
            endcase
            ALUR: case (ID_EX_funct3)
                3'b000: alu_out = ID_EX_funct7[5] ? (alu_A - ex_rs2_data) : (alu_A + ex_rs2_data);
                3'b001: alu_out = alu_A << shamt;
                3'b010: alu_out = ($signed(alu_A) < $signed(ex_rs2_data)) ? 32'd1 : 32'd0;
                3'b011: alu_out = (alu_A < ex_rs2_data) ? 32'd1 : 32'd0;
                3'b100: alu_out = alu_A ^ ex_rs2_data;
                3'b101: begin
                    if (ID_EX_funct7[5])
                        alu_out = $signed(alu_A) >>> shamt;
                    else
                        alu_out = alu_A >> shamt;
                end
                3'b110: alu_out = alu_A | ex_rs2_data;
                3'b111: alu_out = alu_A & ex_rs2_data;
                default: alu_out = 32'b0;
            endcase
            default: alu_out = 32'b0;
        endcase
    end

    // --- 分支条件判断（用前递后的数据） ---
    reg branch_taken;
    always @(*) begin
        case (ID_EX_funct3)
            3'b000: branch_taken = (ex_rs1_data == ex_rs2_data);         // beq
            3'b001: branch_taken = (ex_rs1_data != ex_rs2_data);         // bne
            3'b100: branch_taken = ($signed(ex_rs1_data) < $signed(ex_rs2_data));  // blt
            3'b101: branch_taken = ($signed(ex_rs1_data) >= $signed(ex_rs2_data)); // bge
            3'b110: branch_taken = (ex_rs1_data < ex_rs2_data);          // bltu
            3'b111: branch_taken = (ex_rs1_data >= ex_rs2_data);         // bgeu
            default: branch_taken = 1'b0;
        endcase
    end

    // --- 跳转/分支目标地址计算 ---
    wire [31:0] ex_branch_target =
        ID_EX_is_jal                         ? (ID_EX_PC + ID_EX_imm) :
        ID_EX_is_jalr                        ? ((ex_rs1_data + ID_EX_imm) & ~32'h1) :
        (ID_EX_is_branch & branch_taken)     ? (ID_EX_PC + ID_EX_imm) :
                                               32'h0;  // 不使用

    // --- 是否需要跳转（flush 信号） ---
    wire ex_pc_sel = ID_EX_is_jal | ID_EX_is_jalr | (ID_EX_is_branch & branch_taken);

    assign flush          = ex_pc_sel;
    assign branch_target  = ex_branch_target;

    // --- EX 阶段产生的"写回数据候选"（用于前递，不含 load） ---
    // 注意：load 的数据要到 MEM 阶段才拿到，所以 load-use 需要 stall

    //这是一个中间信号，它表示：仅仅在 EX 这个阶段，我们能算出的“准备写回”的数据是什么？
    //如果是算术指令，结果自然是 ALU 算出来的 alu_out
    //如果是跳转指令（JAL/JALR），我们要把返回地址（也就是当前指令的下一条，PC+4）存进寄存器里，所以结果是 ID_EX_PC + 32'd4

    //实际上是废代码，使用的是451行的ex_mem_wb_data
    wire [31:0] ex_wb_candidate =
        (ID_EX_is_jal | ID_EX_is_jalr) ? (ID_EX_PC + 32'd4) :
                                          alu_out;



    // ================================================================
    //  Load-Use 冒险检测
    //
    //  如果 EX 阶段是 load，且 ID 阶段的源寄存器依赖 load 的目标，
    //  则需要暂停 1 拍。
    // ================================================================
    //stall = (EX 段是 LOAD) && (LOAD 的 rd == ID 段的 rs1 或 rs2)
    assign stall = ID_EX_is_load && (ID_EX_rd != 5'b0) &&
                   ((ID_EX_rd == id_rs1 && (id_is_alur || id_is_alui || id_is_load ||
                                            id_is_store || id_is_branch || id_is_jalr)) ||
                    (ID_EX_rd == id_rs2 && (id_is_alur || id_is_branch || id_is_store)));



    // ================================================================
    //              ★ EX/MEM 流水线寄存器 ★
    // ================================================================
    reg [31:0] EX_MEM_alu_out;
    reg [31:0] EX_MEM_rs2_data;
    reg [31:0] EX_MEM_PC;
    // EX_MEM_rd, EX_MEM_wb_en 已在前面声明为 reg
    reg [2:0]  EX_MEM_funct3;
    reg        EX_MEM_mem_w;
    reg        EX_MEM_is_load, EX_MEM_is_store;
    reg        EX_MEM_is_jal, EX_MEM_is_jalr;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            EX_MEM_alu_out  <= 32'h0;
            EX_MEM_rs2_data <= 32'h0;
            EX_MEM_PC       <= 32'h0;
            EX_MEM_rd       <= 5'h0;
            EX_MEM_funct3   <= 3'h0;
            EX_MEM_mem_w    <= 1'b0;
            EX_MEM_wb_en    <= 1'b0;
            EX_MEM_is_load  <= 1'b0;
            EX_MEM_is_store <= 1'b0;
            EX_MEM_is_jal   <= 1'b0;
            EX_MEM_is_jalr  <= 1'b0;
        end else begin
            EX_MEM_alu_out  <= alu_out;
            EX_MEM_rs2_data <= ex_rs2_data;  // 前递后的 rs2 数据
            EX_MEM_PC       <= ID_EX_PC;
            EX_MEM_rd       <= ID_EX_rd;
            EX_MEM_funct3   <= ID_EX_funct3;
            EX_MEM_mem_w    <= ID_EX_mem_w;
            EX_MEM_wb_en    <= ID_EX_wb_en;
            EX_MEM_is_load  <= ID_EX_is_load;
            EX_MEM_is_store <= ID_EX_is_store;
            EX_MEM_is_jal   <= ID_EX_is_jal;
            EX_MEM_is_jalr  <= ID_EX_is_jalr;
        end
    end

    // --- EX/MEM 阶段的写回数据（用于前递给 EX 阶段） ---
    // 注意：如果 EX/MEM 是 load，这个值还不是最终值！
    // 但 load-use stall 已经保证了 load 后面不会立即用到
    // 所以到下一拍时 load 会在 MEM/WB 阶段，用 wb_data 前递

    //这个信号是真正用来“往回传”（前递给 EX 阶段）的数据 。它处于 MEM 阶段
    //这个信号直接连到了前递实现（278起）里的 ex_rs1_data 和 ex_rs2_data 的多路选择器里，供 EX 阶段使用
    assign ex_mem_wb_data =
        (EX_MEM_is_jal | EX_MEM_is_jalr) ? (EX_MEM_PC + 32'd4) :
        EX_MEM_is_load                    ? Data_in :  // MEM阶段load数据已到
                                            EX_MEM_alu_out;

    // ================================================================
    //              ★ MEM 阶段 ★
    //  与外部总线交互：输出地址、数据、控制信号
    // ================================================================
    assign mem_w    = EX_MEM_mem_w;
    assign Addr_out = EX_MEM_alu_out;
    assign Data_out = EX_MEM_rs2_data;
    assign dm_ctrl  = EX_MEM_funct3;
    assign CPU_MIO  = EX_MEM_is_load | EX_MEM_is_store;

    // ================================================================
    //              ★ MEM/WB 流水线寄存器 ★
    // ================================================================
    // MEM_WB_rd, MEM_WB_wb_en 已在前面声明为 reg
    reg [31:0] MEM_WB_alu_out;
    reg [31:0] MEM_WB_mem_data;
    reg [31:0] MEM_WB_PC;
    reg        MEM_WB_is_load;
    reg        MEM_WB_is_jal, MEM_WB_is_jalr;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            MEM_WB_alu_out  <= 32'h0;
            MEM_WB_mem_data <= 32'h0;
            MEM_WB_PC       <= 32'h0;
            MEM_WB_rd       <= 5'h0;
            MEM_WB_wb_en    <= 1'b0;
            MEM_WB_is_load  <= 1'b0;
            MEM_WB_is_jal   <= 1'b0;
            MEM_WB_is_jalr  <= 1'b0;
        end else begin
            MEM_WB_alu_out  <= EX_MEM_alu_out;
            MEM_WB_mem_data <= Data_in;  // 从总线/内存读回的数据
            MEM_WB_PC       <= EX_MEM_PC;
            MEM_WB_rd       <= EX_MEM_rd;
            MEM_WB_wb_en    <= EX_MEM_wb_en;
            MEM_WB_is_load  <= EX_MEM_is_load;
            MEM_WB_is_jal   <= EX_MEM_is_jal;
            MEM_WB_is_jalr  <= EX_MEM_is_jalr;
        end
    end

    // ================================================================
    //                    ★ WB 阶段 ★
    //  选择写回数据，写入寄存器堆
    // ================================================================
    assign wb_data =
        MEM_WB_is_load                      ? MEM_WB_mem_data        :
        (MEM_WB_is_jal | MEM_WB_is_jalr)   ? (MEM_WB_PC + 32'd4)   :
                                              MEM_WB_alu_out;

    // 写回寄存器堆（时钟上升沿）
    always @(posedge clk) begin
        if (!reset && MEM_WB_wb_en && (MEM_WB_rd != 5'b0))
            rf[MEM_WB_rd] <= wb_data;
    end

endmodule