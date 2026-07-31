`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: PCPU_TOP  (Project 3 — 流水线 + trap/中断 + 自定义小程序)
// Description: 在 Project 2 顶层基础上新增中断源：
//   1. 指令ROM 加载 custom_int.coe（自定义中断演示程序，主循环 + ISR）
//   2. 外部中断源：BTNC/BTNU/BTNL/BTNR 统一进入 PCPU 外部 INT
//      ecall 和异常由 PCPU 内部按指令同步产生 trap
//   3. PCPU.INT 端口由原来的 1'b0 改为 int_sources[2:0]
//   4. 其余外设、总线、显示通道与 Project 2 完全相同
//
//   注意：切换 ROM 内容请在 Vivado 中重新生成 IP 核并加载新的 coe 文件。
//////////////////////////////////////////////////////////////////////////////////

module PCPU_TOP(
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
wire [31:0] counter_out;

// U1_PCPU
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
wire        data_ram_we;
wire [9:0]  ram_addr;
wire [31:0] ram_data_in;
wire [3:0]  ram_wea;
assign ram_wea = data_ram_we ? wea_mem : 4'b0000;

// U5_Multi_8CH32
wire [31:0] Disp_num;
wire [7:0]  LE_out;
wire [7:0]  point_out;

// ===================== 模块实例化 =====================

// =============================================================
// 中断源链路 (v5) —— 自动识别按钮空闲电平 + 独立消抖 + 跨时钟翻转同步
//   关键修复:
//     1) 不再假设用户按钮一定是 active-high。复位释放后先等待输入稳定,
//        记录每个按钮的空闲电平; 后续只把“偏离空闲电平”视作按下。
//        这样 active-high / active-low 板卡都不会在上电后自发触发 BTN 中断。
//     2) 每个物理按钮独立同步和消抖, 最后再按中断类别合并。某一个按钮脚
//        电平异常时, 不会在 OR 之前污染同类里的另一个正常按钮。
//
//   新链路 (按数据流方向):
//     BTN_out[3:0] (异步)
//        └─► [A] 2-FF 同步到 clk 域                      →  btn_sync_1
//        └─► [B] 每键 5ms 稳态消抖                      →  btn_dbnc
//        └─► [C] 复位后 10ms 学习每键空闲电平           →  btn_idle
//        └─► [D] “偏离空闲”变为 pressed, 再做上升沿     →  btn_rising
//        └─► [E] 按类别合并并翻转事件位                 →  btn_event_tog
//        └─► [F] Clk_CPU 域 2-FF 同步器                 →  event_tog_s1
//        └─► [G] Clk_CPU 域翻转检测                     →  btn_irq_pulse
//        └─► PCPU.INT
// =============================================================

localparam BTN_DBNC_MAX = 20'd500_000;    // 100MHz x 5ms
localparam BTN_IDLE_MAX = 20'd1_000_000;  // 100MHz x 10ms

// 原始异步按钮: [0]=BTNC, [1]=BTNU, [2]=BTNL, [3]=BTNR
wire [3:0] irq_btn_raw = BTN_out[3:0];

// [A] 2-FF 同步器: 把异步 BTN 拉进 100MHz clk 域, 消除亚稳态
reg [3:0] btn_sync_0, btn_sync_1;
always @(posedge clk or posedge rst_i) begin
    if (rst_i) begin
        btn_sync_0 <= 4'b0000;
        btn_sync_1 <= 4'b0000;
    end else begin
        btn_sync_0 <= irq_btn_raw;
        btn_sync_1 <= btn_sync_0;
    end
end

// [B] 消抖: 输入与稳态相等就清零计数; 否则计数累加, 累计 ~5ms 都不变才更新稳态
reg [19:0] dbnc_cnt [0:3];
reg [3:0]  btn_dbnc;
integer irq_btn_i;
always @(posedge clk or posedge rst_i) begin
    if (rst_i) begin
        for (irq_btn_i = 0; irq_btn_i < 4; irq_btn_i = irq_btn_i + 1) begin
            dbnc_cnt[irq_btn_i] <= 20'd0;
            btn_dbnc[irq_btn_i] <= 1'b0;
        end
    end else begin
        for (irq_btn_i = 0; irq_btn_i < 4; irq_btn_i = irq_btn_i + 1) begin
            if (btn_sync_1[irq_btn_i] == btn_dbnc[irq_btn_i]) begin
                dbnc_cnt[irq_btn_i] <= 20'd0;
            end else if (dbnc_cnt[irq_btn_i] == BTN_DBNC_MAX) begin
                dbnc_cnt[irq_btn_i] <= 20'd0;
                btn_dbnc[irq_btn_i] <= btn_sync_1[irq_btn_i];
            end else begin
                dbnc_cnt[irq_btn_i] <= dbnc_cnt[irq_btn_i] + 20'd1;
            end
        end
    end
end

// [C] 复位释放后等待消抖状态稳定, 记录每个按钮的空闲电平。
reg [19:0] idle_cnt;
reg [3:0]  btn_idle;
reg        btn_idle_ready;
always @(posedge clk or posedge rst_i) begin
    if (rst_i) begin
        idle_cnt       <= 20'd0;
        btn_idle       <= 4'b0000;
        btn_idle_ready <= 1'b0;
    end else if (!btn_idle_ready) begin
        if (idle_cnt == BTN_IDLE_MAX) begin
            btn_idle       <= btn_dbnc;
            btn_idle_ready <= 1'b1;
        end else begin
            idle_cnt <= idle_cnt + 20'd1;
        end
    end
end

// [D] clk 域 pressed 上升沿检测。pressed=1 表示按钮电平偏离空闲电平。
wire [3:0] btn_pressed = btn_idle_ready ? (btn_dbnc ^ btn_idle) : 4'b0000;
reg [3:0] btn_pressed_d;
always @(posedge clk or posedge rst_i) begin
    if (rst_i) btn_pressed_d <= 4'b0000;
    else       btn_pressed_d <= btn_pressed;
end
wire [3:0] btn_rising = btn_pressed & ~btn_pressed_d;   // 1 clk 拍宽
wire [1:0] btn_class_rising = {
    btn_rising[2] | btn_rising[3],   // Class 3: BTNL/BTNR
    btn_rising[0] | btn_rising[1]    // Class 1: BTNC/BTNU
};

// [E] 每次稳定按下翻转事件位
reg [1:0] btn_event_tog;
always @(posedge clk or posedge rst_i) begin
    if (rst_i) btn_event_tog <= 2'b00;
    else       btn_event_tog <= btn_event_tog ^ btn_class_rising;
end

// [F] 跨时钟到 Clk_CPU 域: 标准 2-FF 同步器
reg [1:0] event_tog_s0, event_tog_s1;
always @(posedge Clk_CPU or posedge rst_i) begin
    if (rst_i) begin
        event_tog_s0 <= 2'b00;
        event_tog_s1 <= 2'b00;
    end else begin
        event_tog_s0 <= btn_event_tog;
        event_tog_s1 <= event_tog_s0;
    end
end

// [G] Clk_CPU 域翻转检测。边沿事件先展宽几拍再送入 CPU；
//     PCPU 内部按上升沿入队，所以展宽不会造成一次按键重复中断。
reg [1:0] event_tog_d;
wire [1:0] btn_irq_edge;
always @(posedge Clk_CPU or posedge rst_i) begin
    if (rst_i) event_tog_d <= 2'b00;
    else       event_tog_d <= event_tog_s1;
end
assign btn_irq_edge = event_tog_s1 ^ event_tog_d;

localparam [2:0] BTN_IRQ_HOLD = 3'd4;
reg [2:0] btn_irq_hold0;
reg [2:0] btn_irq_hold1;

always @(posedge Clk_CPU or posedge rst_i) begin
    if (rst_i) begin
        btn_irq_hold0 <= 3'd0;
        btn_irq_hold1 <= 3'd0;
    end else begin
        if (btn_irq_edge[0])
            btn_irq_hold0 <= BTN_IRQ_HOLD;
        else if (btn_irq_hold0 != 3'd0)
            btn_irq_hold0 <= btn_irq_hold0 - 3'd1;

        if (btn_irq_edge[1])
            btn_irq_hold1 <= BTN_IRQ_HOLD;
        else if (btn_irq_hold1 != 3'd0)
            btn_irq_hold1 <= btn_irq_hold1 - 3'd1;
    end
end

wire [1:0] btn_irq_req = {|btn_irq_hold1, |btn_irq_hold0};

// [G] 周期 timer 中断：快档约每 1 秒触发一次
localparam TIMER_RELOAD = 24'd6_250_000;
reg [23:0] timer_cnt;
reg        timer_irq_pulse;
always @(posedge Clk_CPU or posedge rst_i) begin
    if (rst_i) begin
        timer_cnt       <= 24'd0;
        timer_irq_pulse <= 1'b0;
    end else if (timer_cnt == TIMER_RELOAD) begin
        timer_cnt       <= 24'd0;
        timer_irq_pulse <= 1'b1;
    end else begin
        timer_cnt       <= timer_cnt + 24'd1;
        timer_irq_pulse <= 1'b0;
    end
end

// 验收口径下三类 trap 为：外部中断(ecall 外部来源)、系统调用 ecall、异常。
// 因此这里只把按钮接到外部中断；timer_irq_pulse 保留但不接入，避免周期事件干扰验收。
wire [2:0] int_sources = {btn_irq_req[1], 1'b0, btn_irq_req[0]};

// ---------- U1: PCPU（流水线 + 中断版） ----------
PCPU U1(
    .clk(Clk_CPU),
    .reset(rst_i),
    .MIO_ready(1'b1),           // 总线始终就绪
    .inst_in(spo),
    .Data_in(Data_read),        // 从 dm_controller 来的处理后数据
    .mem_w(mem_w),
    .PC_out(PC_out),
    .Addr_out(Adder_out),
    .Data_out(Data_out),
    .dm_ctrl(dm_ctrl),
    .CPU_MIO(CPU_MIO),
    .INT(int_sources)           // 外部按钮中断；ecall/异常由 PCPU 内部指令产生
);

// ---------- U2: ROMD (指令ROM IP核) ----------
// ★ Project 3：加载 custom_int.coe 作为初始化文件
//    程序结构：0x00 主循环初始化 + 开中断，0x18 主循环体，0x80 ISR (MTVEC)
ROMD U2(
    .a(PC_out[11:2]),           // 字地址 = PC >> 2，取低10位
    .spo(spo)
);

// ---------- U3: dm_controller ----------
dm_controller U3(
    .mem_w(mem_w),
    .Addr_in(Adder_out),
    .Data_write(Data_out),
    .dm_ctrl(dm_ctrl),
    .Data_read_from_dm(Cpu_data4bus),
    .Data_read(Data_read),
    .Data_write_to_dm(Data_write_to_dm),
    .wea_mem(wea_mem)
);

// ---------- U3_R: RAM_B (数据RAM IP核) ----------
// ★ Project 3：custom_int.coe 程序未访问数据 RAM，
//    可继续使用 Project 2 的 D_snakeDEMO.coe，或生成空 coe，都不影响验收
RAM_B U3_R(
    .addra(ram_addr),
    .clka(clka0_i),
    .dina(Data_write_to_dm),
    .wea(ram_wea),
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
    .counter_out(counter_out),
    .counter0_out(counter0_OUT),
    .counter1_out(counter1_OUT),
    .counter2_out(counter2_OUT),
    .Cpu_data4bus(Cpu_data4bus),
    .ram_data_in(ram_data_in),
    .ram_addr(ram_addr),
    .data_ram_we(data_ram_we),
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
    .data3(counter_out),
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
    .SW0(1'b0),                 // Project 3 固定纯 hex，避免调试 PC 时被 AC 模式干扰
    .flash(clkdiv[12]),
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
    .counter2_OUT(counter2_OUT),
    .counter_out(counter_out)
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
