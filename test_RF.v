module RF(
    input         clk,
    input         rst,          // 高电平复位 (top层传入的是 ~rstn)
    input         RFWr,         // 写使能
    input  [15:0] sw_i,         // 开关输入 (保留接口)
    input  [4:0]  A1,           // 读地址1 (rs1)
    input  [4:0]  A2,           // 读地址2 (rs2)
    input  [4:0]  A3,           // 写地址 (rd)
    input  [31:0] WD,           // 写入数据
    output [31:0] RD1,          // 读数据1
    output [31:0] RD2           // 读数据2
);

    reg [31:0] rf[31:0];        // 32个32位寄存器
    integer i;

    // 写操作 (时序逻辑)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1)
                rf[i] <= 32'b0; // 复位清零
        end
        else if (RFWr && (A3 != 5'b0)) begin 
            // 只有写使能有效 且 目标寄存器不是x0 时才写入
            rf[A3] <= WD;
        end
    end

    // 读操作 (组合逻辑)
    // x0 恒为 0
    assign RD1 = (A1 == 5'b0) ? 32'b0 : rf[A1];
    assign RD2 = (A2 == 5'b0) ? 32'b0 : rf[A2];

endmodule