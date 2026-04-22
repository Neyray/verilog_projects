`timescale 1ns / 1ps
// ============================================================
// dm_controller：数据存储器访问控制器
//
// dm_ctrl[2:0] = funct3（与 SCPU 约定一致）：
//   010 → lw / sw   （字，4字节）
//   001 → lh / sh   （半字，2字节，lh 有符号扩展）
//   000 → lb / sb   （字节，lb 有符号扩展）
//   101 → lhu       （半字，无符号扩展）
//   100 → lbu       （字节，无符号扩展）
//
// Addr_in[1:0] 决定字节/半字在字内的偏移：
//   字节偏移  0,1,2,3
//   半字偏移  0,2
//
// wea_mem[3:0]：字节使能，驱动 blk_mem_gen_0 的 wea 端口
//   wea_mem[3] → 字节3（高字节），wea_mem[0] → 字节0（低字节）
// ============================================================
module dm_controller(
    input         mem_w,                // 1=store, 0=load
    input  [31:0] Addr_in,              // 访存字节地址
    input  [31:0] Data_write,           // CPU 写出的原始数据（rs2）
    input  [2:0]  dm_ctrl,              // funct3
    input  [31:0] Data_read_from_dm,    // RAM 读出的原始 32 位数据
    output [31:0] Data_read,            // 经符号扩展/对齐后给 CPU 的数据
    output [31:0] Data_write_to_dm,     // 字节对齐后写入 RAM 的数据
    output [3:0]  wea_mem               // 字节使能
);

    wire [1:0] byte_off = Addr_in[1:0]; // 字节偏移（0~3）
    wire       half_off = Addr_in[1];   // 半字偏移（0 或 1）

    // ================================================================
    // 写使能 wea_mem 生成
    // ================================================================
    reg [3:0] wea;
    always @(*) begin
        if (!mem_w) begin
            wea = 4'b0000;           // load 不写
        end else begin
            case (dm_ctrl)
                3'b010: wea = 4'b1111;   // sw：写全部4字节
                3'b001: wea = half_off ? 4'b1100 : 4'b0011; // sh
                3'b000:                               // sb
                    case (byte_off)
                        2'b00: wea = 4'b0001;
                        2'b01: wea = 4'b0010;
                        2'b10: wea = 4'b0100;
                        2'b11: wea = 4'b1000;
                        default: wea = 4'b0000;
                    endcase
                default: wea = 4'b0000;
            endcase
        end
    end
    assign wea_mem = wea;

    // ================================================================
    // 写数据对齐（把 CPU 的数据移到正确的字节位置）
    // ================================================================
    reg [31:0] dw;
    always @(*) begin
        case (dm_ctrl)
            3'b010: dw = Data_write;    // sw：直接写
            3'b001:                     // sh：移到对应半字位置
                dw = half_off ? {Data_write[15:0], 16'b0}
                              : {16'b0, Data_write[15:0]};
            3'b000:                     // sb：移到对应字节位置
                case (byte_off)
                    2'b00: dw = {24'b0, Data_write[7:0]};
                    2'b01: dw = {16'b0, Data_write[7:0], 8'b0};
                    2'b10: dw = {8'b0,  Data_write[7:0], 16'b0};
                    2'b11: dw = {Data_write[7:0], 24'b0};
                    default: dw = 32'b0;
                endcase
            default: dw = Data_write;
        endcase
    end
    assign Data_write_to_dm = dw;

    // ================================================================
    // 读数据提取 + 符号扩展
    // ================================================================
    // 先从 32 位字中提取正确的字节/半字
    wire [7:0]  byte_sel =
        (byte_off == 2'b00) ? Data_read_from_dm[7:0]   :
        (byte_off == 2'b01) ? Data_read_from_dm[15:8]  :
        (byte_off == 2'b10) ? Data_read_from_dm[23:16] :
                              Data_read_from_dm[31:24];

    wire [15:0] half_sel =
        half_off ? Data_read_from_dm[31:16] : Data_read_from_dm[15:0];

    reg [31:0] dr;
    always @(*) begin
        case (dm_ctrl)
            3'b010: dr = Data_read_from_dm;                     // lw
            3'b001: dr = {{16{half_sel[15]}}, half_sel};        // lh  有符号
            3'b101: dr = {16'b0, half_sel};                     // lhu 无符号
            3'b000: dr = {{24{byte_sel[7]}}, byte_sel};         // lb  有符号
            3'b100: dr = {24'b0, byte_sel};                     // lbu 无符号
            default: dr = Data_read_from_dm;
        endcase
    end
    assign Data_read = dr;

endmodule