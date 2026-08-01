// ============================================================================
// la32_defs.vh — LA32R-2S 全局宏定义（冻结，见 SPEC.md §6/§7）
// 所有模块共享：uop 位段 / 译码总线 / ALUOP 编码 / FU / 分支类型 / 例外码 / CSR 地址
// ============================================================================
`ifndef LA32_DEFS_VH
`define LA32_DEFS_VH

// ---------------- FU 类型 (3bit) ----------------
`define FU_ALU   3'd0
`define FU_MDU   3'd1
`define FU_LSU   3'd2
`define FU_BR    3'd3
`define FU_CSR   3'd4

// ---------------- ALUOP 编码 (6bit) ----------------
`define AOP_ADD    6'd0
`define AOP_SUB    6'd1
`define AOP_SLT    6'd2
`define AOP_SLTU   6'd3
`define AOP_AND    6'd4
`define AOP_OR     6'd5
`define AOP_NOR    6'd6
`define AOP_XOR    6'd7
`define AOP_SLL    6'd8
`define AOP_SRL    6'd9
`define AOP_SRA    6'd10
`define AOP_LUI    6'd11   // lu12i.w : imm << 12
`define AOP_PASSJ  6'd12   // rj 直通
`define AOP_PASSK  6'd13   // rk/imm 直通
`define AOP_PCADD  6'd14   // pc + imm (pcaddu12i)
`define AOP_MUL    6'd16
`define AOP_MULH   6'd17
`define AOP_MULHU  6'd18
`define AOP_DIV    6'd19
`define AOP_DIVU   6'd20
`define AOP_MOD    6'd21
`define AOP_MODU   6'd22
`define AOP_LDB    6'd24
`define AOP_LDH    6'd25
`define AOP_LDW    6'd26
`define AOP_LDBU   6'd27
`define AOP_LDHU   6'd28
`define AOP_STB    6'd29
`define AOP_STH    6'd30
`define AOP_STW    6'd31
`define AOP_LL     6'd32
`define AOP_SC     6'd33
`define AOP_CSRRD    6'd34
`define AOP_CSRWR    6'd35
`define AOP_CSRXCHG  6'd36
`define AOP_RDCNTVL  6'd37
`define AOP_RDCNTVH  6'd38
`define AOP_RDCNTID  6'd39
`define AOP_SYSCALL  6'd40
`define AOP_BREAK    6'd41
`define AOP_ERTN     6'd42
`define AOP_NOP      6'd43
`define AOP_CPUCFG   6'd44   // cpucfg rd, rj —— 恒返回 0（上报无 cache）

// ---------------- 分支类型 (4bit) ----------------
`define BR_NONE   4'd0
`define BR_BEQ    4'd1
`define BR_BNE    4'd2
`define BR_BLT    4'd3
`define BR_BGE    4'd4
`define BR_BLTU   4'd5
`define BR_BGEU   4'd6
`define BR_B      4'd7
`define BR_BL     4'd8
`define BR_JIRL   4'd9

// ---------------- 例外码 (6bit, ECODE 对齐 LA32r 手册) ----------------
`define EXC_NONE  6'h00
`define EXC_INT   6'h00   // 中断（以 CSR 侧标记区分）
`define EXC_ADEF  6'h08
`define EXC_ALE   6'h09
`define EXC_SYS   6'h0b
`define EXC_BRK   6'h0c
`define EXC_INE   6'h0d
// 内部用高位标记中断（不进 ECODE 字段本身，由 csr_file 转换）
`define EXCF_IS_INT 6'h20

// ---------------- CSR 地址 (14bit) ----------------
`define CSR_CRMD    14'h000
`define CSR_PRMD    14'h001
`define CSR_EUEN    14'h002
`define CSR_ECFG    14'h004
`define CSR_ESTAT   14'h005
`define CSR_ERA     14'h006
`define CSR_BADV    14'h007
`define CSR_EENTRY  14'h00c
`define CSR_CPUID   14'h020
`define CSR_SAVE0   14'h030
`define CSR_SAVE1   14'h031
`define CSR_SAVE2   14'h032
`define CSR_SAVE3   14'h033
`define CSR_TID     14'h040
`define CSR_TCFG    14'h041
`define CSR_TVAL    14'h042
`define CSR_TICLR   14'h044
`define CSR_LLBCTL  14'h060

// ---------------- 译码总线 DEC (ID→RN, 每路一条) ----------------
`define DEC_PC       31:0
`define DEC_IMM      63:32
`define DEC_ALUOP    69:64
`define DEC_FU       72:70
`define DEC_RD_WEN   73
`define DEC_RJ       78:74
`define DEC_RK       83:79
`define DEC_RD       88:84
`define DEC_SERIAL   89
`define DEC_BRTYPE   93:90
`define DEC_EXCPT    99:94
`define DEC_VALID    100
`define DEC_USE_RJ   101
`define DEC_USE_RK   102
`define DEC_PRED_TAKEN  103      // v3 BPU：前端预测标记（随指令到 EX 验证）
`define DEC_PRED_TARGET 135:104
`define DEC_BR_CAT      137:136  // 分支类别（BPU 更新用）
`define DEC_W        138

// ---------------- uop 包 (RN→IQ→EX), SPEC §6 ----------------
`define UOP_PC       31:0
`define UOP_IMM      63:32
`define UOP_ALUOP    69:64
`define UOP_FU       72:70
`define UOP_PD       78:73
`define UOP_PJ       84:79
`define UOP_PK       90:85
`define UOP_PJ_RDY   91
`define UOP_PK_RDY   92
`define UOP_RD_WEN   93
`define UOP_RD_ARCH  98:94
`define UOP_SERIAL   99
`define UOP_BR_TYPE  103:100
`define UOP_ROB      108:104
`define UOP_CKPT     111:109
`define UOP_EXCPT    117:112
`define UOP_USE_IMM  118       // k 源取 imm（=~USE_RK），否则读 PRF
`define UOP_SPARE    127:119
`define UOP_PRED_TAKEN  128    // v3 BPU：该分支被前端预测 taken
`define UOP_PRED_TARGET 160:129
`define UOP_BR_CAT    162:161
`define UOP_W        163

// ---------------- 分支类别（BPU） ----------------
`define BC_COND    2'd0   // beq/bne/blt/bltu/bge/bgeu（方向查 PHT）
`define BC_UNCOND  2'd1   // b / 非 ret 非 call 的 jirl（恒 taken）
`define BC_CALL    2'd2   // bl / jirl rd!=0（恒 taken + RAS 压栈）
`define BC_RET     2'd3   // jirl r0,r1,0（恒 taken + RAS 弹栈给目标）

// ---------------- 结构参数 ----------------
`define ROB_DEPTH   32
`define IQ_DEPTH    16
`define CKPT_DEPTH  8
`define PRF_SIZE    64
`define SB_DEPTH    4    // store buffer
`define CKPT_INVALID 3'd7

`endif // LA32_DEFS_VH
