//实验任务1，2，跑马灯

module compare_game(
    input clk,//系统时钟，来自FPGA板
    input rstn,//复位信号，低电平有效
    input CPU_RESETN,
    input [15:0]sw_i,
    output reg [15:0]led_o,

);

//常量类型
parameter TARGET=4'b1010;

wire match;
assign match=(sw_i[3:0]==TARGET);

//reg表示寄存器类型，可以在always块赋值
reg[3:0]led_cnt;//led计数器，记录当前点亮到第几个led
reg[24:0]div_cnt;//分频计数器，用于降低流水灯速度

//分频器设计
always @(posedge clk or negedge rstn)begin
    if(!rstn)begin
        div_cnt<=25'd0;//复位时清零
    end else begin
        //<=是非阻塞赋值，用于时序逻辑,25'd表示25位十进制,下划线仅用于标明清楚
        if(div_cnt>=25'd1_000_000)//计数到100万
            div_cnt<=25'd0;//重新开始
        else
            div_cnt<=div_cnt+1'b1;//继续计数
    end
end

//降低速度​：系统时钟频率很高（如50MHz），直接用它控制LED会太快，人眼无法分辨

//​产生时间基准​：每计数1,000,000个时钟周期产生一个tick脉冲

//​控制流水灯速度​：只有收到tick脉冲时，流水灯才移动一次

wire tick=(div_cnt==25'd1_000_000);//产生脉冲信号
//当div_cnt等于1000000,tick=1（持续一个时钟周期）
//tick并不是"匹配失败的条件"，而是分频计时器产生的时间基准脉冲。

//当 div_cnt计数到1,000,000时，tick产生一个时钟周期的高电平脉冲

//这个脉冲用于控制流水灯的移动速度

//匹配成功与否由 match信号判断，与 tick无关



//LED控制逻辑（核心部分）
always @(posedge clk or negedge rstn)begin
    if(!rstn)begin
        //复位时的初始状态
        led_o<=16'b0000_0000_0000_0000;
        led_cnt<=4'd0;
    end else begin
        if(match)begin
            //匹配成功，只点亮LED15
            led_o<=16'b1000_0000_0000_0000;
            led_cnt<=4'd0;
        end else begin
            //不匹配：流水灯效果
            if(tick)begin
                if(led_cnt<=4'd15)begin
                    led_o[15-led_cnt]<=1'b1;//点亮对应LED
                    led_cnt<=led_cnt+1'b1;//计数器加一
                end else begin
                    //全部点亮后重新开始
                    led_o<=16'b0000_0000_0000_0000;
                    led_cnt<=4'd0;
                end
            end
        end
    end
end

endmodule