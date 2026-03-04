//
// 第七讲: EXT (立即数扩展) 模块
// [cite: 619-630]
//
module EXT (
    input  [31:0] instr, // 传入完整指令
    input  [1:0]  EXTOp, // 扩展类型
    output reg [31:0] immout // 32位立即数输出
);

    // 译码立即数
    wire [11:0] i_imm = instr[31:20]; // [cite: 555]
    wire [11:0] s_imm = {instr[31:25], instr[11:7]}; // [cite: 556]
    
    // 扩展逻辑 [cite: 632-638]
    always @(*) begin
        case (EXTOp)
            2'b01: // I-type
                immout = {{20{i_imm[11]}}, i_imm}; // 符号扩展
            2'b10: // S-type
                immout = {{20{s_imm[11]}}, s_imm}; // 符号扩展
            default:
                immout = 32'h0;
        endcase
    end

endmodule