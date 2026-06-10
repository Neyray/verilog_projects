    .option norvc
    .text
    .globl _start

# custom_int.s -- Project 3 three trap-class acceptance demo
#
# mcause=1: external interrupt from BTNC/BTNU/BTNL/BTNR
# mcause=2: system call trap from ecall
# mcause=3: exception trap from illegal/unimplemented instruction
#
# After reset, this program executes one ecall and one illegal instruction
# automatically. Then it enters the main loop; pressing any user button
# triggers the external interrupt class.

_start:
    lui   x11, 0xe0000          # 7-seg base = 0xE000_0000
    lui   x12, 0xd0000          # CSR base   = 0xD000_0000
    lui   x15, 0xf0000          # LED base   = 0xF000_0000

    addi  x5,  x0, 0            # external interrupt count
    addi  x6,  x0, 0            # ecall count
    addi  x7,  x0, 0            # exception count
    addi  x8,  x0, 0            # last mcause
    addi  x9,  x0, 0            # flash countdown
    addi  x10, x0, 0            # flash kind: 1=EXT, 2=ECALL, 3=EXC
    addi  x13, x0, 1            # moving LED bit
    addi  x23, x0, 0            # delayed exception demo countdown

    sw    x0, 0(x12)            # mie <- 1, enable external interrupt

    ecall                       # system call trap, mcause=2
    jal   x0, main_loop         # show ecall first; exception is delayed below

    .org 0x80
isr:
    lw    x28, 12(x12)          # read mcause
    add   x8, x28, x0

    addi  x29, x0, 1
    beq   x28, x29, isr_external
    addi  x29, x0, 2
    beq   x28, x29, isr_ecall
    addi  x29, x0, 3
    beq   x28, x29, isr_exception
    sw    x0, 8(x12)            # unknown cause: MRET

isr_external:
    addi  x5, x5, 1
    addi  x9, x0, 5
    addi  x10, x0, 1
    sw    x0, 8(x12)            # MRET

isr_ecall:
    addi  x6, x6, 1
    addi  x9, x0, 5
    addi  x10, x0, 2
    addi  x23, x0, 8            # allow EC411 and A002 frames before exception
    sw    x0, 8(x12)            # MRET

isr_exception:
    addi  x7, x7, 1
    addi  x9, x0, 5
    addi  x10, x0, 3
    sw    x0, 8(x12)            # MRET

    .org 0x180
main_loop:
    # LED[3:0] = moving bit, LED[7:4] = external count low nibble,
    # LED[11:8] = ecall count low nibble, LED[15:12] = exception count low nibble.
    slli  x18, x5, 4
    or    x18, x18, x13
    slli  x19, x6, 8
    or    x18, x18, x19
    slli  x19, x7, 12
    or    x18, x18, x19
    sw    x18, 0(x15)

    beq   x9, x0, show_normal
    addi  x29, x0, 1
    beq   x10, x29, show_external
    addi  x29, x0, 2
    beq   x10, x29, show_ecall
    jal   x0, show_exception

show_external:
    lui   x26, 0xe7100          # E71000ee: external interrupt count
    or    x26, x26, x5
    jal   x0, store_display

show_ecall:
    lui   x26, 0xec411          # EC4110ss: ecall count
    slli  x27, x6, 4
    or    x26, x26, x27
    jal   x0, store_display

show_exception:
    lui   x26, 0xeace0          # EACE00xx: exception count
    or    x26, x26, x7
    jal   x0, store_display

show_normal:
    lui   x26, 0xa0000          # A0cceess: cause/ext/ecall/exception summary
    slli  x27, x8, 16
    or    x26, x26, x27
    slli  x27, x5, 8
    or    x26, x26, x27
    slli  x27, x6, 4
    or    x26, x26, x27
    or    x26, x26, x7

store_display:
    sw    x26, 0(x11)
    beq   x9, x0, delay_start
    addi  x9, x9, -1

delay_start:
    addi  x20, x0, 0
    lui   x21, 0x100
delay_loop:
    addi  x20, x20, 1
    bne   x20, x21, delay_loop

    beq   x23, x0, skip_exception_demo
    addi  x23, x23, -1
    bne   x23, x0, skip_exception_demo
    beq   x7, x0, trigger_exception_demo
    jal   x0, skip_exception_demo
trigger_exception_demo:
    .word 0xffffffff            # illegal instruction exception, mcause=3
skip_exception_demo:

    slli  x13, x13, 1
    addi  x22, x0, 16
    bne   x13, x22, main_loop
    addi  x13, x0, 1
    jal   x0, main_loop
