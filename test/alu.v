module alu(A,B,ALUOp,C);

input [31:0] A,B;
input [2:0] ALUOp;
reg signed [31:0] ta,tb;
output reg [31:0] C;

always @(A or B or ALUOp) begin
    case (ALUOp)
        3'b000: C <= A+B;
        3'b001: C <= A-B;
        3'b010: C <= A&B;
        3'b011: C <= A| B;
        3'b100: C <= A>> B;
        3'b101: C <= $signed(A) >> B;
        3'b110: 
            if(A > B) C <= 1;
            else C <= 0;
        3'b111: 
            if($signed(A) > $signed(B)) C <= 1;
            else C <= 0;
    endcase
end

endmodule