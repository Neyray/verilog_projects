`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: SCPU_TOP
// Description: 修正版顶层模块
//   修正内容：
//   1. 删除 assign instr = spo（instr 未声明）
//   2. SCPU 的 MIO_ready 改为接 1'b1（原来自环接 CPU_MIO 导致非 load/store 时 PC 不更新）
//   3. dm_controller 连接修正：
//      - Data_write 接 CPU 的 Data_out（rs2原始数据），不再接 MIO_BUS 的 ram_data_in
//      - Data_read_from_dm 接 Cpu_data4bus（经MIO_BUS地址译码后的读数据）
//      - Data_read 输出给 CPU 的 Data_in（经符号扩展/字节提取后）
//   4. RAM 的 dina 接 dm_controller 的 Data_write_to_dm（字节对齐后的写数据）
//////////////////////////////////////////////////////////////////////////////////

module SCPU_TOP(
    input clk,
    input rstn,
    input [15:0] sw_i,
    input [4:0]  btn_i,
    output [15:0] led_o,
    output [7:0] disp_an_o,
    output [7:0] disp_seg_o
);

// ===================== 内部信号声明 =====================

// U10_Enter
wire [4:0]  BTN_out;
wire [15:0] SW_out;

// 复位（低有效按钮 → 高有效内部复位）
wire rst_i;
assign rst_i = ~rstn;

// U8_clk_div
wire        Clk_CPU;
wire [31:0] clkdiv;

// 反相时钟
wire clk_i;
assign clk_i = ~Clk_CPU;

wire clka0_i;
assign clka0_i = ~clk;

// U7_SPIO
wire [15:0] LED_out;
wire [1:0]  counter_set;

// U9_Counter_x
wire counter0_OUT;
wire counter1_OUT;
wire counter2_OUT;

// U1_SCPU
wire [31:0] Adder_out;
wire        CPU_MIO;
wire [31:0] Data_out;
wire [31:0] PC_out;
wire [2:0]  dm_ctrl;
wire        mem_w;

// U2_ROMD
wire [31:0] spo;

// U3_dm_controller
wire [31:0] Data_read;
wire [31:0] Data_write_to_dm;
wire [3:0]  wea_mem;

// U3_RAM_B
wire [31:0] douta;

// U4_MIO_BUS
wire [31:0] Cpu_data4bus;
wire        GPIOe0000000_we;
wire        GPIOf0000000_we;
wire [31:0] Peripheral_in;
wire        counter_we;
wire [9:0]  ram_addr;
wire [31:0] ram_data_in;

// U5_Multi_8CH32
wire [31:0] Disp_num;
wire [7:0]  LE_out;
wire [7:0]  point_out;

// 未使用信号
wire [31:0] none;

// ===================== 模块实例化 =====================

// ---------- U1: SCPU ----------
// 修正1: MIO_ready 接 1'b1，不再自环接 CPU_MIO
//        原来接 CPU_MIO 会导致：非 load/store 指令时 CPU_MIO=0 → MIO_ready=0 → PC 不更新！
// 修正2: Data_in 接 dm_controller 的 Data_read（经过符号扩展/字节提取）
SCPU U1(
    .clk(Clk_CPU),
    .reset(rst_i),
    .MIO_ready(1'b1),           // ★ 修正：总线始终就绪
    .inst_in(spo),
    .Data_in(Data_read),        // 从 dm_controller 来的处理后数据
    .mem_w(mem_w),
    .PC_out(PC_out),
    .Addr_out(Adder_out),
    .Data_out(Data_out),
    .dm_ctrl(dm_ctrl),
    .CPU_MIO(CPU_MIO),
    .INT(1'b0)
);

// ---------- U2: ROMD (指令ROM IP核) ----------
ROMD U2(
    .a(PC_out[11:2]),           // 字地址 = PC >> 2，取低10位
    .spo(spo)
);

// ---------- U3: dm_controller ----------
// 修正3: 连接关系完全重写
//   Data_write     ← CPU 的 Data_out（rs2 原始数据）
//   Data_read_from_dm ← Cpu_data4bus（MIO_BUS 选出的读数据，来自 RAM 或外设）
//   Data_read      → CPU 的 Data_in（经过字节提取和符号扩展）
//   Data_write_to_dm → RAM 的 dina（经过字节对齐）
//   wea_mem        → RAM 的 wea（字节使能）
dm_controller U3(
    .mem_w(mem_w),
    .Addr_in(Adder_out),
    .Data_write(Data_out),          // ★ 修正：CPU 的 rs2 原始数据
    .dm_ctrl(dm_ctrl),
    .Data_read_from_dm(Cpu_data4bus),  // MIO_BUS 选出的读数据
    .Data_read(Data_read),          // 给 CPU 的处理后数据
    .Data_write_to_dm(Data_write_to_dm),  // 字节对齐后写入 RAM
    .wea_mem(wea_mem)
);

// ---------- U3_R: RAM_B (数据RAM IP核) ----------
RAM_B U3_R(
    .addra(ram_addr),
    .clka(clka0_i),
    .dina(Data_write_to_dm),    // ★ 修正：用 dm_controller 对齐后的数据写入 RAM
    .wea(wea_mem),              // 字节使能
    .douta(douta)
);

// ---------- U4: MIO_BUS ----------
MIO_BUS U4(
    .clk(clk),
    .rst(rst_i),
    .BTN(BTN_out),
    .SW(SW_out),
    .PC(PC_out),
    .mem_w(mem_w),
    .Cpu_data2bus(Data_out),
    .addr_bus(Adder_out),
    .ram_data_out(douta),
    .led_out(LED_out),
    .counter_out(none),
    .counter0_out(counter0_OUT),
    .counter1_out(counter1_OUT),
    .counter2_out(counter2_OUT),
    .Cpu_data4bus(Cpu_data4bus),
    .ram_data_in(ram_data_in),
    .ram_addr(ram_addr),
    // data_ram_we 不连接（由 dm_controller 的 wea_mem 替代）
    .GPIOf0000000_we(GPIOf0000000_we),
    .GPIOe0000000_we(GPIOe0000000_we),
    .counter_we(counter_we),
    .Peripheral_in(Peripheral_in)
);

// ---------- U5: Multi_8CH32 ----------
Multi_8CH32 U5(
    .clk(clk_i),
    .rst(rst_i),
    .EN(GPIOe0000000_we),
    .LES(64'hFFFFFFFFFFFFFFFF),
    .Switch(SW_out[7:5]),
    .data0(Peripheral_in),
    .data1({2'b00, PC_out[31:2]}),
    .data2(spo),
    .data3(none),
    .data4(Adder_out),
    .data5(Data_out),
    .data6(Cpu_data4bus),
    .data7(PC_out),
    .point_in({clkdiv, clkdiv}),
    .Disp_num(Disp_num),
    .LE_out(LE_out),
    .point_out(point_out)
);

// ---------- U6: SSeg7 ----------
SSeg7 U6(
    .clk(clk),
    .rst(rst_i),
    .SW0(SW_out[0]),
    .flash(clkdiv[12]),   // flash 改回原来的，它本来就是对的
    //.lopt(SW_out[1]),     // ← 新增：SW1 控制高/低16位
    .Hexs(Disp_num),
    .LES(LE_out),
    .point(point_out),
    .seg_an(disp_an_o),
    .seg_sout(disp_seg_o)
);

// ---------- U7: SPIO ----------
SPIO U7(
    .clk(clk_i),
    .rst(rst_i),
    .EN(GPIOf0000000_we),
    .P_Data(Peripheral_in),
    .LED_out(LED_out),
    .counter_set(counter_set),
    .led(led_o)
);

// ---------- U8: clk_div ----------
clk_div U8(
    .clk(clk),
    .rst(rst_i),
    .SW2(SW_out[2]),
    .Clk_CPU(Clk_CPU),
    .clkdiv(clkdiv)
);

// ---------- U9: Counter_x ----------
Counter_x U9(
    .clk(clk_i),
    .rst(rst_i),
    .clk0(clkdiv[6]),
    .clk1(clkdiv[9]),
    .clk2(clkdiv[11]),
    .counter_we(counter_we),
    .counter_val(Peripheral_in),
    .counter_ch(counter_set),
    .counter0_OUT(counter0_OUT),
    .counter1_OUT(counter1_OUT),
    .counter2_OUT(counter2_OUT)
);

// ---------- U10: Enter ----------
Enter U10(
    .clk(clk),
    .BTN(btn_i),
    .SW(sw_i),
    .BTN_out(BTN_out),
    .SW_out(SW_out)
);

endmodule
