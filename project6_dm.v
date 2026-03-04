//
// 第六讲: DM (DATA MEM) 模块
// 实现了32个8位存储单元 [cite: 512]
// 支持小端模式的字(word)、半字(half)、字节(byte)读写 [cite: 515, 521]
//
`define dm_word 3'b000
`define dm_halfword 3'b001
`define dm_halfword_unsigned 3'b010
`define dm_byte 3'b011
`define dm_byte_unsigned 3'b100

module dm (
    input               clk,    // 时钟
    input               DMWr,   // 写使能 [cite: 519]
    input      [5:0]    addr,   // 地址 (手册为32x8位, 5位即可, 但ALU输出32位, 用低位) [cite: 512, 519]
    input      [31:0]   din,    // 写入数据 [cite: 520]
    input      [2:0]    DMType, // 读写类型 (word, byte, etc.) [cite: 521]
    output reg [31:0]   dout    // 读出数据 [cite: 522]
);

    // 32个8位存储单元 (Data Memory) [cite: 512]
    reg [7:0] mem [31:0];

    // 内部地址线 (取地址的低5位)
    wire [4:0] a;
    assign a = addr[4:0];

    // 写操作 (时序逻辑)
    always @(posedge clk) begin
        if (DMWr) begin
            case (DMType)
                `dm_word: begin // 写入32位 (sw)
                    mem[a]   <= din[7:0];   // 小端 
                    mem[a+1] <= din[15:8];
                    mem[a+2] <= din[23:16];
                    mem[a+3] <= din[31:24];
                end
                `dm_halfword: begin // 写入16位 (sh)
                    mem[a]   <= din[7:0];
                    mem[a+1] <= din[15:8];
                end
                `dm_byte: begin // 写入8位 (sb)
                    mem[a] <= din[7:0];
                end
            endcase
        end
    end

    // 读操作 (组合逻辑)
    always @(*) begin
        case (DMType)
            `dm_word: begin // 读32位 (lw)
                dout = {mem[a+3], mem[a+2], mem[a+1], mem[a]};
            end
            `dm_halfword: begin // 读16位有符号 (lh)
                dout = {{16{mem[a+1][7]}}, mem[a+1], mem[a]}; // 符号扩展
            end
            `dm_halfword_unsigned: begin // 读16位无符号 (lhu)
                dout = {{16'h0000}, mem[a+1], mem[a]}; // 零扩展
            end
            `dm_byte: begin // 读8位有符号 (lb)
                dout = {{24{mem[a][7]}}, mem[a]}; // 符号扩展
            end
            `dm_byte_unsigned: begin // 读8位无符号 (lbu)
                dout = {{24'h000000}, mem[a]}; // 零扩展
            end
            default: dout = 32'h0;
        endcase
    end

endmodule