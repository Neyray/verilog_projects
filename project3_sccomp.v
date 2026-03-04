module sccomp(clk, rstn, sw_i, disp_seg_o, disp_an_o);
    input clk;
    input rstn;
    input [15:0] sw_i;
    output [7:0] disp_an_o, disp_seg_o;
    
    reg [31:0] clkdiv;
    wire clk_CPU;
    
    // 时钟分频
    always @(posedge clk or negedge rstn) begin
        if (!rstn) 
            clkdiv <= 0;
        else 
            clkdiv <= clkdiv + 1'b1;
    end
    
    assign clk_CPU = (sw_i[15]) ? clkdiv[27] : clkdiv[25];
    
    // 7段数码管显示相关
    reg [63:0] display_data;
    reg [5:0] led_data_addr;
    reg [63:0] led_disp_data;
    wire [63:0] rom_data_out;
    
    parameter LED_DATA_NUM = 19;
    
    // ROM IP核实例化 - 方案1: 纯组合逻辑ROM
    dist_mem_gen_0 u_led_rom (
        .a(led_data_addr[4:0]),     // 地址输入，5位(0-18)
        .spo(rom_data_out)           // 数据输出 64位
    );
    
    // 产生LED_DATA地址和数据
    always @(posedge clk_CPU or negedge rstn) begin
        if (!rstn) begin
            led_data_addr <= 6'd0;
            led_disp_data <= 64'b1;
        end
        else if (sw_i[0] == 1'b1) begin
            if (led_data_addr == LED_DATA_NUM) begin
                led_data_addr <= 6'd0;
            end
            else begin
                led_data_addr <= led_data_addr + 1'b1;
            end
            led_disp_data <= rom_data_out;
        end
        else begin
            led_data_addr <= led_data_addr;
            led_disp_data <= led_disp_data;
        end
    end
    
    // 其他信号声明
    wire [31:0] instr;
    reg [31:0] reg_data;
    reg [31:0] alu_disp_data;
    reg [31:0] demem_data;
    
    // 为未使用的信号赋默认值
    assign instr = 32'h00000000;
    
    always @(posedge clk_CPU or negedge rstn) begin
        if (!rstn) begin
            reg_data <= 32'h0;
            alu_disp_data <= 32'h0;
            demem_data <= 32'h0;
        end
        else begin
            reg_data <= 32'h0;
            alu_disp_data <= 32'h0;
            demem_data <= 32'h0;
        end
    end
    
    // 选择显示源数据
    always @(*) begin
        if (sw_i[0] == 0) begin
            case (sw_i[14:11])
                4'b1000: display_data = {32'h0, instr};
                4'b0100: display_data = {32'h0, reg_data};
                4'b0010: display_data = {32'h0, alu_disp_data};
                4'b0001: display_data = {32'h0, demem_data};
                default: display_data = {32'h0, instr};
            endcase
        end
        else begin
            display_data = led_disp_data;
        end
    end
    
    // 7段数码管显示模块实例化
    seg7x16 u_seg7x16(
        .clk(clk),
        .rstn(rstn),
        .i_data(display_data[31:0]),
        .o_seg(disp_seg_o),
        .o_sel(disp_an_o)
    );

endmodule