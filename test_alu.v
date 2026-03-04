module alu(
    input signed [31:0] A, B,
    input [4:0] ALUOp,
    output signed [31:0] C,
    output reg Zero
);
    reg signed [31:0] C_r;

    always @(*) begin
        case(ALUOp)
            5'b00011: C_r = A + B; // ADD
            5'b00100: C_r = A - B; // SUB (Branch时使用)
            default:  C_r = 32'h0;
        endcase
        
        // Zero标志生成: 结果为0时置1
        Zero = (C_r == 32'h0) ? 1'b1 : 1'b0;
    end

    assign C = C_r;
endmodule