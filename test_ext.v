module EXT(
    input [31:0] instr,
    input [2:0] EXTOp,
    output reg [31:0] immout
);
    wire [11:0] i_imm = instr[31:20];
    wire [11:0] s_imm = {instr[31:25], instr[11:7]};
    // B型立即数编码 (末位补0)
    wire [12:0] b_imm = {instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [20:0] j_imm = {instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
    
    always @(*) begin
        case(EXTOp)
            3'd0: immout = {{20{i_imm[11]}}, i_imm}; // I
            3'd1: immout = {{20{s_imm[11]}}, s_imm}; // S
            3'd2: immout = {{19{b_imm[12]}}, b_imm}; // B (Branch)
            3'd3: immout = {{11{j_imm[20]}}, j_imm}; // J
            default: immout = 32'b0;
        endcase
    end
endmodule