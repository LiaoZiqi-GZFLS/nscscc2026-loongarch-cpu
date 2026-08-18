# [stage1] RegisteredCommit 定向测试程序
# 覆盖:空ROB派发+立即误预测 / 背靠背误预测 / flush拍与邮箱push同拍 /
#       flush落非空ROB中段(div在飞行) / LL-SC / uncached load-store /
#       syscall异常提交与ertn回跳
# 自检:r10 checksum, r23 syscall次数;结果写到 0x1d000000 起,DONE=0xdeadbeef
    .text
    .globl _start
_start:
    lu12i.w  $r1, 0x1c000          # r1 = 0x1c000000
    ori      $r2, $r1, 0x400       # handler = 0x1c000400
    csrwr    $r2, 0xc              # EENTRY

    addi.w   $r10, $r0, 0          # checksum
    addi.w   $r23, $r0, 0          # syscall count

    # ---- 循环退出误预测(退出拍 flush;循环内 wrong-path 条目在 CM1 fire 被封锁) ----
    addi.w   $r11, $r0, 4
loopA:
    addi.w   $r10, $r10, 1
    addi.w   $r11, $r11, -1
    bne      $r11, $r0, loopA      # taken×3(学习), 退出拍误预测
    add.w    $r10, $r10, $r10      # r10 = 8

    # ---- 背靠背误预测对(B2 为 wrong-path,检验无第二次 flush) ----
    beq      $r0, $r0, skip1       # B1: 恒 taken,首过 BTB miss → 误预测
    addi.w   $r10, $r10, 100       # wrong-path(湮灭)
    addi.w   $r10, $r10, 100       # wrong-path(湮灭)
skip1:
    beq      $r0, $r0, skip2       # B2: 紧跟 B1,首过误预测
    addi.w   $r10, $r10, 7         # wrong-path(湮灭)
skip2:

    # ---- flush 落非空 ROB 中段:误预测分支后跟长延迟 div(wrong-path, 未完成) ----
    addi.w   $r9, $r0, 2
    beq      $r0, $r0, skip3       # 误预测
    div.w    $r12, $r10, $r9       # wrong-path 长延迟(湮灭)
    mul.w    $r12, $r10, $r9       # wrong-path(湮灭)
    addi.w   $r10, $r10, 55        # wrong-path(湮灭)
skip3:
    addi.w   $r10, $r10, 1         # r10 = 9

    # ---- LL/SC ----
    lu12i.w  $r13, 0x1c010         # 数据区 0x1c010000
    addi.w   $r14, $r0, 55
    st.w     $r14, $r13, 0
    ll.w     $r15, $r13, 0
    addi.w   $r15, $r15, 1         # 56
    sc.w     $r15, $r13, 0         # 成功 → r15=1
    add.w    $r10, $r10, $r15      # +1 → 10
    ld.w     $r16, $r13, 0         # 56
    add.w    $r10, $r10, $r16      # +56 → 66

    # ---- uncached 段:清 CRMD.DATM(bits 8:7) 使数据访问 uncached ----
    csrrd    $r17, 0x0             # CRMD
    lu12i.w  $r20, -1              # 0xfffff000
    ori      $r20, $r20, 0xe7f     # 0xfffffe7f = ~0x180
    and      $r17, $r17, $r20
    csrwr    $r17, 0x0
    st.w     $r14, $r13, 4         # uncached store
    ld.w     $r21, $r13, 4         # uncached load → commit FSM + uncachedKick
    add.w    $r10, $r10, $r21      # +55 → 121
    ld.w     $r21, $r13, 0         # 再一次 uncached load
    add.w    $r10, $r10, $r21      # +56 → 177

    # ---- syscall 异常提交 + ertn 回跳(保持 uncached 模式) ----
    syscall  0
    addi.w   $r10, $r10, 1         # ertn 后落这里 → 178

    # ---- 结束:写结果区(uncached,直达内存),DONE magic ----
    lu12i.w  $r24, 0x1d000         # 0x1d000000
    st.w     $r10, $r24, 0         # checksum
    st.w     $r23, $r24, 4         # syscall 次数
    lu12i.w  $r25, 0x5a5a5
    ori      $r25, $r25, 0xa5a     # 0x5a5a5a5a = DONE magic
    st.w     $r25, $r24, 8         # DONE

    # 恢复 CRMD.DATM=2'b01(cached)
    csrrd    $r17, 0x0
    ori      $r22, $r0, 0x180
    or       $r17, $r17, $r22
    csrwr    $r17, 0x0
forever:
    b        forever

    # ---- 异常处理器(0x400 偏移处) ----
    .org 0x400
exc_handler:
    csrrd    $r2, 0x6              # ERA
    addi.w   $r2, $r2, 4
    csrwr    $r2, 0x6
    addi.w   $r23, $r23, 1
    ertn
