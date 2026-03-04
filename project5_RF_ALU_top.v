//实验任务二：  
//1）实现RF部件和ALU部件的关联，使得指定寄存器的数值送入ALU部件参与运算，具体参见下图：
//2）通过SW_i输入双端口要读出的寄存器编号A1，A2，并将读出的数值RD1，RD2送入ALU的A，B输入端，根据设定的ALUOp，计算结果，并显示。
//3）通过SW_i输入要写入寄存器编号和数值A3，WD，再通过步骤2），将计算结果显示出来。
`define ALUOp_add 5'b00001//定义假发操作码
`define ALUOp_sub 5'b00010//定义减法操作码

module alu(
    input signed [31:0]A,B,//有符号32位输入
    input [4:0]ALUOp,//5位操作码
    output signed [31:0]C,//运算结果
    output reg[7:0]Zero//零标志
);

reg signed [31:0] C_r;

//always @(*)表示纯组合逻辑
always @(*)begin
    case(ALUOp)
        `ALUOp_add:C_r=A+B;//加法
        `ALUOp_sub:C_r=A-B;//减法
        default:C_r=32'h0;//默认输出0
    endcase

    //零标志：结果为0是Zero[0]=1
    if(C_r==32'h0)//h表示16进制
        Zero=8'h01;
    else
        Zero=8'h00;
end
assign C=C_r;

endmodule




module RF(
    input clk,
    input rst,
    input RFWr,//写使能信号
    input [15:0] sw_i,
    input [4:0]A1,A2,A3,//读地址1、读地址2、写地址
    input [31:0]WD,//写数据
    output reg [31:0]RD1,RD2//读数据1，读数据2
);

reg [31:0] rf[31:0];//32个32位寄存器

//初始化
integert i;//用于循环变量（仿真用）
initial begin
    for(i=0;i<32;++i)
        rf[i]=i;
end




//写操作（时序逻辑）
//RFWr = 1（写使能有效）
//sw_i[1] = 0（非只读模式）
//A3 != 0（不能写rf[0]）
always @(posedge clk or posedge rst)begin
    if(rst)begin
        for(i=0,i<32;++i)
           rf[i]<=i;//复位到初始值
    end
    else begin
        if(RFWr && sw_i[1]==0 && A3!=0)begin
            rf[A3]<=WD;//写入数据
        end
    end
    rf[0]<=32'h0;//rf[0]永远为0（RISC-V规范）
end

//读操作
always @(*)begin
    RD1=rf[A1];
    RD2=rf[A2];
end

endmodule
//读操作是组合逻辑（地址改变，数据立即输出）
//写操作是时序逻辑（只在时钟上升沿写入）
//这种设计称为"双端口RAM"







module top(
    input clk,
    input rstn,
    input [15:0]sw_i,
    input CPU_RESETN,
    input BTNC,BTNU,BTNL,BTNR,BTND,
    output [7:0]disp_seg_o,
    output [7:0]disp_an_o,
    output [15:0]led_o
);

//时钟分频（调试用）
reg [31:0]clkdiv;
wire Clk_CPU;

always @(posedge clk or negedge rstn)begin
    if(!rstn)
       clkdiv<=0;
    else
       clkdiv<=clkdiv+1'b1;
end

assign Clk_CPU=(sw_i[15])?clkdiv[27]:clkdiv[25];


//输入信号处理
//读模式（sw[2]=0）
assign A1=(sw_i[2]==0)?{2'b00,sw_i[10:8]}:5'b0;
assign A2=(sw_i[2]==0)?{2'b00,sw_i[7:5]}:5'b0;
//sw[10:8] → A1（读寄存器1的地址）
//sw[7:5] → A2（读寄存器2的地址）
//{2'b00, sw_i[10:8]} 将3位扩展到5位




//写模式(sw_i[2]=1)
assign A3 = (sw_i[2] == 1) ? {2'b00, sw_i[10:8]} : 5'b0;
assign WD = (sw_i[2] == 1) ? {{29{sw_i[7]}}, sw_i[7:5]} : 32'h0;
//sw[10:8] → A3（写寄存器地址）
//sw[7:5] → WD（写数据，符号扩展）


//ALU操作控制
assign ALUOp=(sw_i[3]==1)?`ALUOp_add:`ALUOp_sub;
//sw[3]=1 → 加法
//sw[3]=0 → 减法

//寄存器堆
RF u_rf(
    .clk(clk),
    .rst(~rstn),
    .RFWr(RFWr),
    .sw_i(sw_i),
    .A1(A1),
    .A2(A2),
    .A3(A3),
    .WD(WD),
    .RD1(RD1),
    .RD2(RD2)
);





//ALU
assign A_alu = RD1;  // ALU的A输入来自RF的RD1
assign B_alu = RD2;  // ALU的B输入来自RF的RD2

alu u_alu(
    .A(A_alu),
    .B(B_alu),
    .ALUOp(ALUOp),
    .C(C_alu),
    .Zero(Zero)
);






//显示控制逻辑
//循环显示寄存器内容(sw[14]=1)
always @(posedge Clk_CPU or negedge rstn)begin
    if(!rstn)begin
        disp_addr<=6'd0;
    end
    else if(sw_i[14]==1'b1)begin       //显示所有RF内容
        if(disp_addr>=6'd33)
            disp_addr<=6'd0;
        else
        disp_addr<=disp_addr+1'b1;
    end
    else if(sw_i[12]==1'b1)begin          //显示A,B,C,Zero
        if(disp_addr>=6'd5)       //4个值+1个分隔符
            disp_addr<=6'd0;
        else
            disp_addr<=disp_addr+1'b1;
    end
    else begin
        disp_addr<=6'd0;
    end
end
//disp_addr 是显示地址计数器
//在慢时钟（Clk_CPU）下递增，实现轮流显示
//显示完所有内容后自动循环


//显示数据选择
always @(*) begin
    if(sw_i[14] == 1'b1) begin  // 模式1：显示所有寄存器
        if(disp_addr < 32)
            display_data = u_rf.rf[disp_addr];  // 访问RF内部寄存器
        else
            display_data = 64'hFFFFFFFFFFFFFFFF;  // 分隔符
    end
    else if(sw_i[12] == 1'b1) begin  // 模式2：显示运算过程
        case(disp_addr)
            6'd0: display_data = {32'h0, A_alu};      // 显示A
            6'd1: display_data = {32'h0, B_alu};      // 显示B
            6'd2: display_data = {32'h0, C_alu};      // 显示C（结果）
            6'd3: display_data = {56'h0, Zero};       // 显示Zero标志
            default: display_data = 64'hFFFFFFFFFFFFFFFF;
        endcase
    end
    else begin
        display_data = {32'h0, C_alu};  // 默认：只显示运算结果
    end
end
/*
u_rf.rf[disp_addr] 解释：

u_rf 是RF模块的实例名
.rf[disp_addr] 访问该实例内部的寄存器数组
这种写法允许上层模块"窥探"子模块内部信号
*/

assign led_o = C_alu[15:0];  // 在LED上显示ALU结果的低16位

//数码管驱动实例化
seg7x16 u_seg7x16(
    .clk(clk),
    .rstn(rstn),
    .i_data(display_data),
    .disp_mode(1'b0),      // Hex译码模式
    .o_seg(disp_seg_o),
    .o_sel(disp_an_o)
);