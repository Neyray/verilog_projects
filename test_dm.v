module dm(
    input clk,
    input DMWr,               // 写使能
    input [31:0] addr,        // 地址 (来自ALU)
    input [31:0] din,         // 写入数据 (来自RF RD2)
    input [2:0] DMType,       // 读写类型 (来自Ctrl)
    output reg [31:0] dout    // 读出数据
);

    reg [7:0] dmem[127:0];    // 定义小容量内存用于仿真 (128字节)
    // 提示：如果考试测试程序较大，可将 [127:0] 改为 [1023:0] 或更大

    wire [31:0] addr_byte = addr; // 字节地址

    // 读操作 (组合逻辑)
    always @(*) begin
        case(DMType)
            // lw (Load Word)
            3'b010: dout = {dmem[addr_byte+3], dmem[addr_byte+2], dmem[addr_byte+1], dmem[addr_byte]};
            
            // lh (Load Half) - 符号扩展
            3'b001: dout = {{16{dmem[addr_byte+1][7]}}, dmem[addr_byte+1], dmem[addr_byte]};
            
            // lb (Load Byte) - 符号扩展
            3'b000: dout = {{24{dmem[addr_byte][7]}}, dmem[addr_byte]};
            
            // lhu (Load Half Unsigned) - 零扩展
            3'b101: dout = {16'b0, dmem[addr_byte+1], dmem[addr_byte]};
            
            // lbu (Load Byte Unsigned) - 零扩展
            3'b100: dout = {24'b0, dmem[addr_byte]};
            
            default: dout = 32'b0;
        endcase
    end

    // 写操作 (时钟上升沿)
    always @(posedge clk) begin
        if (DMWr) begin
            case(DMType)
                // sw (Store Word)
                3'b010: begin 
                    dmem[addr_byte]   <= din[7:0];
                    dmem[addr_byte+1] <= din[15:8];
                    dmem[addr_byte+2] <= din[23:16];
                    dmem[addr_byte+3] <= din[31:24];
                end
                
                // sh (Store Half)
                3'b001: begin 
                    dmem[addr_byte]   <= din[7:0];
                    dmem[addr_byte+1] <= din[15:8];
                end
                
                // sb (Store Byte)
                3'b000: begin 
                    dmem[addr_byte]   <= din[7:0];
                end
            endcase
        end
    end

endmodule