# 定义变量，方便后续修改
TARGET = test.out
SRC = alu.v tb.v
WAVE_FILE = test.vcd

# 默认执行的目标：直接输入 make 就会依次执行 编译、运行、看波形
all: compile run wave

# 第一步：编译
compile:
	iverilog -o $(TARGET) $(SRC)

# 第二步：生成波形
run: 
	vvp $(TARGET)

# 第三步：打开波形
wave:
	gtkwave $(WAVE_FILE)

# 清理垃圾文件
clean:
	rm -f $(TARGET) $(WAVE_FILE)