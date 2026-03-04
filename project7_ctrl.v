//
// 第七讲: Ctrl (控制器) 模块
// 根据指令译码生成所有控制信号 [cite: 559, 561-573]
//
`define ALUOp_add 5'b00011 // 根据手册附录定义
`define ALUOp_sub 5'b00100 // 假设: 0100000 + 000
`define ALUOp_nop 5'b00000

module ctrl (
    input  [6:0] Op,      // [cite: 562]
    input  [6:0] Funct7,  // [cite: 563]
    input  [2:0] Funct3,  // [cite: 563]
    
    output RegWrite, // RF写使能 [cite: 565]
    output MemWrite, // DM写使能 [cite: 566]
    output [1:0] EXTOp,    // 立即数扩展类型 [cite: 567]
    output [4:0] ALUOp,    // ALU操作类型 [cite: 568]
    output ALUSrc,   // ALU的B源选择 [cite: 570]
    output [2:0] DMType, // DM读写类型 [cite: 571]
    output [1:0] WDSel    // RF写数据源 (MemtoReg) [cite: 572]
);

    // --- 译码逻辑 (根据手册第7讲 4.2.2 和 附录) ---
    
    // R-type: add, sub [cite: 577, 658]
    wire rtype = (Op == 7'b0110011);
    wire i_add = rtype & (Funct7 == 7'b0000000) & (Funct3 == 3'b000); // [cite: 578]
    wire i_sub = rtype & (Funct7 == 7'b0100000) & (Funct3 == 3'b000); // [cite: 579]

    // I-type (ALU): addi [cite: 586, 664]
    wire itype_r = (Op == 7'b0010011);
    wire i_addi = itype_r & (Funct3 == 3'b000); // [cite: 587]

    // I-type (Load): lw, lh, lb, lhu, lbu [cite: 581, 666]
    wire itype_l = (Op == 7'b0000011);
    wire i_lw  = itype_l & (Funct3 == 3'b010); // [cite: 584]
    wire i_lh  = itype_l & (Funct3 == 3'b001); // [cite: 583]
    wire i_lb  = itype_l & (Funct3 == 3'b000); // [cite: 582]
    wire i_lhu = itype_l & (Funct3 == 3'b101); // [cite: 672]
    wire i_lbu = itype_l & (Funct3 == 3'b100); // [cite: 671]

    // S-type (Store): sw, sh, sb [cite: 673]
    wire stype = (Op == 7'b0100011);
    wire i_sw  = stype & (Funct3 == 3'b010); // [cite: 590]
    wire i_sh  = stype & (Funct3 == 3'b001); // [cite: 592]
    wire i_sb  = stype & (Funct3 == 3'b000); // [cite: 591]

    // --- 控制信号生成 ---

    // 1. RF写使能 (R-type, I-type-ALU, I-type-Load)
    assign RegWrite = rtype | itype_r | itype_l; // [cite: 594]
    
    // 2. DM写使能 (S-type)
    assign MemWrite = stype; // [cite: 595]

    // 3. ALU B源 (I-type-ALU, I-type-Load, S-type)
    assign ALUSrc = itype_r | itype_l | stype; // [cite: 596]

    // 4. RF写数据源 (WDSel / MemtoReg)
    // 00: ALU_out, 01: MEM_out
    assign WDSel[0] = itype_l; // 只有Load指令才从MEM写回RF [cite: 598]
    assign WDSel[1] = 1'b0; // [cite: 599]

    // 5. ALU操作
    // 假设: 00011=add, 00100=sub
    assign ALUOp[4] = 1'b0;
    assign ALUOp[3] = 1'b0;
    assign ALUOp[2] = i_sub; // sub
    assign ALUOp[1] = i_add | i_addi | itype_l | stype; // add (所有I/S型都用ALU算地址) [cite: 605, 606]
    assign ALUOp[0] = i_add | i_addi | itype_l | stype; // add [cite: 605, 606]

    // 6. 立即数扩展类型 (EXTOp)
    // 00: R-type (unused)
    // 01: I-type (addi, lw) [cite: 609]
    // 10: S-type (sw) [cite: 608]
    assign EXTOp[1] = stype;
    assign EXTOp[0] = itype_r | itype_l;

    // 7. DM读写类型
    assign DMType[2] = i_lbu; // [cite: 616]
    assign DMType[1] = i_lb | i_sb | i_lhu; // [cite: 617]
    assign DMType[0] = i_lh | i_sh | i_lb | i_sb; // [cite: 618]

endmodule