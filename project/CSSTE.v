`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: CSSTE
// Target Devices: xc7a100tcsg324-1 (Nexys 4 DDR / A7)
// Description: CSSTE 顶层模块，连接CPU核心、总线、存储器及各类外设
// Fix Log:
//   1. 新增 dm_controller (U3_DM) 实例，正确处理字节/半字/字访存
//   2. SCPU 的 dm_ctrl 输出接入 dm_controller
//   3. blk_mem_gen_0 的 wea[3:0] 改由 dm_controller 的 wea_mem 驱动
//   4. dm_controller 的 Data_read 输出接入 MIO_BUS 的 ram_data_out
//////////////////////////////////////////////////////////////////////////////////

module CSSTE(
    //声明顶层端口，与约束文件相匹配
    //这部分是自定义的，用来实现pdf中的接口连接，即如果两个端口接在一起，那么共用一个信号
    //wire 是 PDF 框图中连线的 Verilog 表达。两个端口接同一根 wire = PDF 里画了一根线
    //连接它们。每根 wire 只能由一个 output 端口驱动，但可以被多个 input 端口读取。PDF
    // 没有画出来的内部信号，也可以根据功能需要自行补充 wire。
    input         clk,        // 100MHz 原始主时钟
    input         rstn,       // 复位信号 (低电平有效)
    input  [15:0] sw_i,       // 16个拨码开关
    input  [4:0]  btn_i,      // 5个方向按键
    output [15:0] led_o,      // 16个LED灯
    output [7:0]  disp_an_o,  // 数码管位选
    output [7:0]  disp_seg_o  // 数码管段选
    );

    // --- 内部信号声明 ---
    wire [31:0] clkdiv;
    wire Clk_CPU;
    wire [31:0] PC, Inst, Addr, Data_out, CPU_Data4Bus;
    wire [31:0] ram_data_out, ram_data_in, Peripheral_in, counter_out;
    wire [15:0] sw_out;
    wire [4:0]  btn_out;
    wire [9:0]  ram_addr;
    wire [1:0]  counter_set;
    wire [15:0] led_out;
    wire [2:0]  dm_ctrl;       // CPU 访存控制信号 (字节/半字/字 及符号位)
    wire [3:0]  wea_mem;       // 字节使能写信号，来自 dm_controller
    wire [31:0] dm_data_read;  // 经 dm_controller 对齐处理后的读数据
    wire [31:0] dm_data_write; // 经 dm_controller 对齐处理后的写数据
    //testac.coe
    wire CPU_MIO;   // CPU 正在访问 MIO 的指示信号
    wire mem_w, data_ram_we, counter_we, GPIOf0000000_we, GPIOe0000000_we;
    wire counter0_OUT, counter1_OUT, counter2_OUT;

    // 显示总线
    wire [31:0] Disp_num;

    // 内部逻辑使用高电平复位
    wire rst = ~rstn;

    // U9: 输入处理模块
    Enter U9(
        .clk(clk),
        .BTN(btn_i),
        .SW(sw_i),
        .BTN_out(btn_out),
        .SW_out(sw_out)
    );

    // U1: 时钟分频器
    clk_div U1(
        .clk(clk),
        .rst(rst),
        .SW2(sw_out[2]),
        .clkdiv(clkdiv),
        .Clk_CPU(Clk_CPU)
    );

    // U10: 单周期 CPU 核心
    SCPU U10(
        .clk(Clk_CPU),
        .reset(rst),
        .MIO_ready(1'b1),
        .inst_in(Inst),
        .Data_in(CPU_Data4Bus),
        .mem_w(mem_w),
        .PC_out(PC),
        .Addr_out(Addr),
        .Data_out(Data_out),
        .dm_ctrl(dm_ctrl),    // [修复] 不再悬空，接入 dm_controller
        //testac.coe
        .CPU_MIO(CPU_MIO),   // ← 改这里，不再悬空
        .INT(1'b0)
    );

    // U2: 指令 ROM IP核
    dist_mem_gen_0 U2 (
        .a(PC[11:2]),
        .spo(Inst)
    );

    // U3_DM: 数据存储器访问控制器 [新增]
    // 根据 dm_ctrl 信号，处理字节/半字/字的读写对齐与符号扩展
    dm_controller U3_DM(
        .mem_w(mem_w),
        .Addr_in(Addr),
        .Data_write(Data_out),
        .dm_ctrl(dm_ctrl),
        .Data_read_from_dm(ram_data_out),  // 来自 RAM 的原始数据
        .Data_read(dm_data_read),           // 对齐/扩展后送给总线
        .Data_write_to_dm(dm_data_write),   // 对齐后写入 RAM 的数据
        .wea_mem(wea_mem)                   // 字节使能，驱动 RAM wea
    );

    // U3: 数据 RAM IP核
    blk_mem_gen_0 U3 (
        .clka(~clk),
        .wea(wea_mem),          // [修复] 4位字节使能，来自 dm_controller
        .addra(ram_addr),
        .dina(dm_data_write),   // [修复] 经对齐处理的写数据
        .douta(ram_data_out)
    );

    // U4: MIO 总线控制器
    MIO_BUS U4(
        .clk(clk),
        .rst(rst),
        .BTN(btn_out),
        .SW(sw_out),
        .PC(PC),
        .mem_w(mem_w),
        .Cpu_data2bus(Data_out),
        .addr_bus(Addr),
        .ram_data_out(dm_data_read),  // [修复] 使用经 dm_controller 处理的读数据
        .led_out(led_out),
        .counter_out(counter_out),
        .counter0_out(counter0_OUT),
        .counter1_out(counter1_OUT),
        .counter2_out(counter2_OUT),
        .Cpu_data4bus(CPU_Data4Bus),
        .ram_data_in(ram_data_in),
        .ram_addr(ram_addr),
        .data_ram_we(data_ram_we),
        .GPIOf0000000_we(GPIOf0000000_we),
        .GPIOe0000000_we(GPIOe0000000_we),
        .counter_we(counter_we),
        .Peripheral_in(Peripheral_in)
        //实际上并没有这个信号
        .lopt(CPU_MIO)        // ← 加这一行
    );

    // U5: 多路显示数据选择器
    Multi_8CH32 U5(
        .clk(~clk),
        .rst(rst),
        .EN(GPIOe0000000_we),
        .Switch(sw_out[7:5]),
        .point_in({clkdiv, clkdiv}),
        .LES(64'b0),
        .data0(Peripheral_in),
        .data1(PC),
        .data2(Inst),
        .data3(counter_out),
        .data4(Addr),
        .data5(Data_out),
        .data6(CPU_Data4Bus),
        .data7(PC),
        .point_out(),
        .LE_out(),
        .Disp_num(Disp_num)
    );

    // U6: 七段数码管驱动模块
    SSeg7 U6(
        .clk(clk),
        .rst(rst),
        .SW0(sw_out[0]),
        .flash(clkdiv[25]),
        .Hexs(Disp_num),
        .point(8'b0),
        .LES(8'b0),
        .seg_an(disp_an_o),
        .seg_sout(disp_seg_o)
    );

    // U7: SPIO 外设接口 (控制LED)
    SPIO U7(
        .clk(clk),
        .rst(rst),
        .EN(GPIOf0000000_we),
        .P_Data(Peripheral_in),
        .led(led_o),
        .counter_set(counter_set),
        .LED_out(led_out),
        .GPIOf0()
    );

    // U11: 硬件计数器模块
    Counter_x U11(
        .clk(clk),
        .rst(rst),
        .clk0(clkdiv[6]),
        .clk1(clkdiv[9]),
        .clk2(clkdiv[11]),
        .counter_we(counter_we),
        .counter_val(Peripheral_in),
        .counter_ch(counter_set),
        .counter0_OUT(counter0_OUT),
        .counter1_OUT(counter1_OUT),
        .counter2_OUT(counter2_OUT),
        .counter_out(counter_out)
    );

endmodule