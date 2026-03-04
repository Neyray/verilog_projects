`timescale 1ms/1ms

// testbench for simulation
module tb();
    reg [31:0] A,B;
    wire [31:0] C;
    reg [2:0] ALUOp;
    reg [10:0] cnt;
    // instantiation of ALU
    alu U_ALU(.A(A),.B(B),.ALUOp(ALUOp),.C(C));

    initial begin
        $dumpfile("test.vcd");//指定生成的vcd文件名称
        $dumpvars;// 默认记录所有信号到 vcd 文件中
        $display("TEST");
        A=32'h00000003;
        B=32'h00000002;
        ALUOp=3'b000;
        cnt=10'b0;
        #(100) $finish;// 设置仿真停止时间
    end

   always begin
        #(5) ALUOp <= ALUOp ^ 3'b001; // 加上 <= 赋值符号
        cnt <= cnt + 1;               // 建议也加上 <=
    end
endmodule
