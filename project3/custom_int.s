    .option norvc
    .text
    .globl _start

# custom_int.s -- Project 3 中断序列锁小游戏 v3
#
# BTNU/BTN1 是本程序唯一的实时输入：每次稳定按下都会进入一次 ISR。
# 主循环显示一个“序列锁”小游戏：
#   LED[7:0]  : 移动光标，按 1、2、4、8、16 循环
#   LED[15:8] : 当前目标位
# 当低 8 位光标与高 8 位目标重合时按下 BTNU。目标顺序固定为：
#   0x02 -> 0x08 -> 0x01 -> 0x10
# 按对会推进当前进度；按错会增加罚分并把进度重置为 0。
# 连续完成四步后，胜利计数器加 1。
#
# ISR 内没有软件延时，只更新游戏状态并写 MRET。
# 因此中断处理结束后能很快回到被打断的主循环状态。

_start:
    lui   x11, 0xe0000          # 7-seg base = 0xE000_0000
    lui   x12, 0xd0000          # CSR base   = 0xD000_0000
    lui   x15, 0xf0000          # LED base   = 0xF000_0000
    addi  x10, x0, 1            # cursor mask (low LED group)
    addi  x13, x0, 0            # stage: 0..3
    addi  x14, x0, 0            # penalty counter
    addi  x16, x0, 0            # win counter
    addi  x23, x0, 0            # flash countdown
    addi  x24, x0, 0            # flash kind: 1=OK, 2=BAD, 3=WIN
    sw    x0, 0(x12)            # mie <- 1
    jal   x0, main_loop

    .org 0x80
isr:
    # Recompute expected mask from stable stage x13. Do not depend on the
    # main loop's temporary target register, because INT may arrive mid-update.
    addi  x28, x0, 2            # stage 0 target = 0x02
    beq   x13, x0, isr_compare
    addi  x29, x0, 1
    beq   x13, x29, isr_target_1
    addi  x29, x0, 2
    beq   x13, x29, isr_target_2
    addi  x28, x0, 16           # stage 3 target = 0x10
    jal   x0, isr_compare
isr_target_1:
    addi  x28, x0, 8            # stage 1 target = 0x08
    jal   x0, isr_compare
isr_target_2:
    addi  x28, x0, 1            # stage 2 target = 0x01

isr_compare:
    bne   x10, x28, isr_wrong

isr_correct:
    addi  x13, x13, 1
    addi  x28, x0, 4
    bne   x13, x28, isr_step_ok
    addi  x16, x16, 1           # full sequence completed
    addi  x13, x0, 0
    addi  x23, x0, 4
    addi  x24, x0, 3            # WIN flash
    sw    x0, 8(x12)            # MRET

isr_step_ok:
    addi  x23, x0, 2
    addi  x24, x0, 1            # OK flash
    sw    x0, 8(x12)            # MRET

isr_wrong:
    addi  x14, x14, 1           # penalty++
    addi  x13, x0, 0            # reset sequence progress
    addi  x23, x0, 3
    addi  x24, x0, 2            # BAD flash
    sw    x0, 8(x12)            # MRET

    .org 0x100
main_loop:
    # target mask x18 = sequence[stage]
    addi  x18, x0, 2
    beq   x13, x0, target_done
    addi  x30, x0, 1
    beq   x13, x30, target_1
    addi  x30, x0, 2
    beq   x13, x30, target_2
    addi  x18, x0, 16
    jal   x0, target_done
target_1:
    addi  x18, x0, 8
    jal   x0, target_done
target_2:
    addi  x18, x0, 1

target_done:
    slli  x25, x18, 8           # high byte = target
    or    x25, x25, x10         # low byte  = cursor
    sw    x25, 0(x15)

    beq   x23, x0, show_normal
    addi  x30, x0, 1
    beq   x24, x30, show_ok
    addi  x30, x0, 2
    beq   x24, x30, show_bad

show_win:
    lui   x26, 0x600d0          # 600D00ww
    or    x26, x26, x16
    jal   x0, store_display
show_ok:
    lui   x26, 0xc0de0          # C0DE000s
    or    x26, x26, x13
    jal   x0, store_display
show_bad:
    lui   x26, 0xbad00          # BAD000pp
    or    x26, x26, x14
    jal   x0, store_display
show_normal:
    lui   x26, 0xa0000          # A000ppss: penalty in byte1, stage in byte0
    slli  x27, x14, 8
    or    x27, x27, x13
    or    x26, x26, x27

store_display:
    sw    x26, 0(x11)
    beq   x23, x0, delay_start
    addi  x23, x23, -1

delay_start:
    addi  x8, x0, 0
    lui   x9, 0x60              # visible frame delay (~0.25s at fast CPU)
delay_loop:
    addi  x8, x8, 1
    bne   x8, x9, delay_loop

    slli  x30, x10, 1           # compute next cursor in scratch first
    addi  x31, x0, 32
    bne   x30, x31, use_shifted_cursor
    addi  x10, x0, 1
    jal   x0, main_loop
use_shifted_cursor:
    add   x10, x30, x0
    jal   x0, main_loop
