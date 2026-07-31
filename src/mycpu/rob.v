// ============================================================================
// rob.v — 32 项重排序缓冲（2 分配 / 4 写回 / 2 提交，环形）
//   - 项内容：{pc, rd_arch, pd_new, pd_old, rf_wen, is_store, done, excpt, badv, wdata}
//   - 窗口成员关系由 [head, head+count) 判定，flush 无需逐项清 valid
//   - 例外/中断只在头部处理（精确例外）；例外 = 全机清尾（tail<=head, count<=0）
//   - 中断在头指令未 done 时也可采样（era=头 pc，ertn 后重执行）
//   - ertn 为 C4 串行点：提交时 ROB 已排空，提交+redirect 同拍
//   - flush_wen_cnt：窗口内 rf_wen=1 项数，供例外时 freelist head 回滚（O(1) 回收）
// ============================================================================
`include "la32_defs.vh"

module rob(
  input        clk,
  input        rst_n,
  // 分配（uop 只取部分字段入项，其余位有意不用）
  /* verilator lint_off UNUSEDSIGNAL */
  input  [1:0] alloc,
  input  [`UOP_W-1:0] alloc_uop0,
  input  [`UOP_W-1:0] alloc_uop1,
  /* verilator lint_on UNUSEDSIGNAL */
  input  [5:0] alloc_pdold0,
  input  [5:0] alloc_pdold1,
  output [4:0] tail0,
  output [4:0] tail1,
  output       full,
  output       empty,
  // 完成写回 x4（lane0/lane1/mdu/lsu，无仲裁——不同项）
  input        wb0_valid,
  input  [4:0] wb0_rob,
  input  [31:0] wb0_wdata,
  input  [5:0] wb0_excpt,
  input  [31:0] wb0_badv,
  input        wb1_valid,
  input  [4:0] wb1_rob,
  input  [31:0] wb1_wdata,
  input  [5:0] wb1_excpt,
  input  [31:0] wb1_badv,
  input        wb2_valid,
  input  [4:0] wb2_rob,
  input  [31:0] wb2_wdata,
  input  [5:0] wb2_excpt,
  input  [31:0] wb2_badv,
  input        wb3_valid,
  input  [4:0] wb3_rob,
  input  [31:0] wb3_wdata,
  input  [5:0] wb3_excpt,
  input  [31:0] wb3_badv,
  // 分支误预测：tail 回滚到 bru_rob+1，误路径项作废
  input        bru_flush,
  input  [4:0] bru_rob,
  output [4:0] tail_cur,
  // 提交 <=2 条（cmt0 较老）
  output       cmt0_valid,
  output [31:0] cmt0_pc,
  output [4:0] cmt0_rd,
  output       cmt0_wen,
  output [31:0] cmt0_wdata,
  output [5:0] cmt0_pdnew,
  output [5:0] cmt0_pdold,
  output       cmt0_is_store,
  output [4:0] cmt0_tag,
  output       cmt1_valid,
  output [31:0] cmt1_pc,
  output [4:0] cmt1_rd,
  output       cmt1_wen,
  output [31:0] cmt1_wdata,
  output [5:0] cmt1_pdnew,
  output [5:0] cmt1_pdold,
  output       cmt1_is_store,
  output [4:0] cmt1_tag,
  // 例外/中断（头部处理）
  output reg       exc_active,
  output reg [5:0] exc_code,
  output reg [31:0] exc_era,
  output reg [31:0] exc_badv,
  output reg       exc_redirect,   // 一拍脉冲：全机 flush + 跳 redirect_pc
  input  [31:0] eentry,
  input  [31:0] era_csr,
  output reg [31:0] redirect_pc,   // exc: eentry / ertn: era_csr
  input        int_pending,
  output [4:0] head_tag,           // 集成新增：当前头项号（IQ serial 判定）
  output       ertn_commit,        // 集成新增：头项为 ERTN 且本拍提交
  output reg   rob_empty,
  // 例外恢复辅助：例外检测拍锁存"窗口内 rf_wen=1 项数"并保持，
  // 供下一拍 exc_flush 时 freelist head 回滚（O(1) 回收）
  output reg [5:0] flush_wen_cnt,
  // 例外检测拍组合拉高：供 rename 当拍禁止分派（防分配泄漏）
  output       exc_pending
);

  // ---------------- 项存储 ----------------
  reg [31:0] e_pc    [0:31];
  reg [4:0]  e_rd    [0:31];
  reg [5:0]  e_pdnew [0:31];
  reg [5:0]  e_pdold [0:31];
  reg        e_wen   [0:31];
  reg        e_store [0:31];
  reg        e_ertn  [0:31];   // 集成新增：项为 ERTN 指令
  reg        e_done  [0:31];
  reg [5:0]  e_excpt [0:31];
  reg [31:0] e_badv  [0:31];
  reg [31:0] e_wdata [0:31];

  reg [4:0] head, tail;
  reg [5:0] count;              // 0..32

  // ROB 环形区间判断：tag ∈ (from, tail) 开区间（bru 回滚清槽用）
  function in_range;
    input [4:0] tag;
    input [4:0] from;
    input [4:0] tl;
    reg [4:0] d1, d2;
    begin
      d1 = tag - from;
      d2 = tl - from;
      in_range = (d2 != 5'd0) && (d1 != 5'd0) && (d1 < d2);
    end
  endfunction

  // ---- 两阶段分配：rename 的 uop0/uop1 是寄存器输出（T+1 才有效），
  //      而 alloc/pdold 是组合输出（T 有效）。T 沿只锁存 alloc/pdold 并推进
  //      tail；T+1 沿用 alloc_r + 当前 alloc_uop*（恰好是 T 拍分派的 uop）
  //      写项内容，索引取 uop 自带 UOP_ROB 标签（与 IQ/EX 全机一致）。
  reg [1:0] alloc_r;
  reg [5:0] alloc_pdold0_r, alloc_pdold1_r;

  assign tail0    = tail;
  assign tail1    = tail + 5'd1;
  assign tail_cur = tail;
  assign full     = (count >= 6'd31);   // 保证可一次收 2 条
  assign empty    = (count == 6'd0);

  // store 判定（T+1 写项时从当时 alloc_uop* 译出——与 alloc_r 同拍）
  wire u0_store = (alloc_uop0[`UOP_FU] == `FU_LSU) &&
                  (alloc_uop0[`UOP_ALUOP] == `AOP_STB ||
                   alloc_uop0[`UOP_ALUOP] == `AOP_STH ||
                   alloc_uop0[`UOP_ALUOP] == `AOP_STW ||
                   alloc_uop0[`UOP_ALUOP] == `AOP_SC);
  wire u1_store = (alloc_uop1[`UOP_FU] == `FU_LSU) &&
                  (alloc_uop1[`UOP_ALUOP] == `AOP_STB ||
                   alloc_uop1[`UOP_ALUOP] == `AOP_STH ||
                   alloc_uop1[`UOP_ALUOP] == `AOP_STW ||
                   alloc_uop1[`UOP_ALUOP] == `AOP_SC);

  // ---------------- 头部状态 ----------------
  wire [4:0] h1 = head + 5'd1;
  wire       head_v    = (count > 6'd0);
  wire       head_done = head_v && e_done[head];
  wire       head_exc  = head_done && (e_excpt[head] != `EXC_NONE);
  // 中断：头指令为 era，无需等 done
  wire       int_taken = int_pending && head_v;
  wire       do_exc    = head_exc || int_taken;

  // ---------------- 提交（组合） ----------------
  wire cmt0_v = head_done && !head_exc && !int_taken;
  wire cmt1_v = cmt0_v && (count > 6'd1) && e_done[h1] &&
                (e_excpt[h1] == `EXC_NONE);

  assign cmt0_valid   = cmt0_v;
  assign cmt0_pc      = e_pc[head];
  assign cmt0_rd      = e_rd[head];
  assign cmt0_wen     = e_wen[head];
  assign cmt0_wdata   = e_wdata[head];
  assign cmt0_pdnew   = e_pdnew[head];
  assign cmt0_pdold   = e_pdold[head];
  assign cmt0_is_store= e_store[head];
  assign cmt0_tag     = head;
  assign cmt1_valid   = cmt1_v;
  assign cmt1_pc      = e_pc[h1];
  assign cmt1_rd      = e_rd[h1];
  assign cmt1_wen     = e_wen[h1];
  assign cmt1_wdata   = e_wdata[h1];
  assign cmt1_pdnew   = e_pdnew[h1];
  assign cmt1_pdold   = e_pdold[h1];
  assign cmt1_is_store= e_store[h1];
  assign cmt1_tag     = h1;

  wire [1:0] cmt_cnt = {1'b0, cmt0_v} + {1'b0, cmt1_v};

  // ertn：与 cmt0 同拍（C4 已保证 ertn 在头且 ROB 已排空；
  // 仍做尾清防御 C4 被破坏的情况）
  wire ertn_cmt = e_ertn[head] && cmt0_v;
  assign head_tag    = head;
  assign ertn_commit = ertn_cmt;

  // ---------------- exc_wen_cnt（组合）/ flush_wen_cnt 保持寄存器 ----------------
  assign exc_pending = do_exc;

  // 分支回滚后项数 = (bru_rob+1) - (head+cmt_cnt)，mod 32
  wire [4:0] bru_cnt5 = bru_rob + 5'd1 - head - {3'd0, cmt_cnt};

  integer wi;
  reg [4:0] woff;
  reg [5:0] exc_wen_cnt;
  // do_exc 与 bru_flush 同拍时（n51 实证）：ROB 走 do_exc 分支，tail 不回滚，
  // 但 rename 侧同拍响应 bru_flush 用 ckpt 回滚 freelist head——(bru_rob,tail)
  // 回滚区项的 pd 已被归还一次。exc_wen_cnt 若仍按 count 全窗统计会把这些
  // 项再计一次 → 次拍 exc_flush 回滚过头，圈回已提交指令的现役映射
  // （4ddc 的 r27 pd 被圈回 → handler ld.w 分到并写 1d0000 → r27 腐化）。
  // 统计窗口取 min(count, bru 回滚后项数)。
  wire [5:0] exc_win = bru_flush ? {1'b0, bru_cnt5} : count;
  always @* begin
    exc_wen_cnt = 6'd0;
    for (wi = 0; wi < 32; wi = wi + 1) begin
      woff = wi[4:0] - head;
      if (({1'b0, woff} < exc_win) && e_wen[wi])
        exc_wen_cnt = exc_wen_cnt + 6'd1;
    end
    rob_empty = (count == 6'd0);
  end

  // 在飞分配回收（n49 死锁根因）：T-1 拍分派的 uop 内容写本应在 T 沿发生，
  // 被 do_exc/ertn 分支抢占而取消——其 e_wen 从未置位，上方 exc_wen_cnt
  // 漏计，但 freelist pd 已消耗 → 每次例外泄漏 1~2 个物理寄存器。
  // n49 定时器中断 ~30 次后 freelist 耗尽（ROB 空 + fl 空 → rename 永久停）。
  // UOP_RD_WEN 在 rename 侧已扣 rd==0（不耗 pd），与实际 pd 消耗一一对应。
  // 同拍 bru_flush 时在飞 uop 若落在 bru 回滚区（比分支年轻），其 pd 已由
  // rename 侧 bru ckpt 回滚归还，inflight_wen 不得重复计数。
  wire infl0_bru = bru_flush && in_range(alloc_uop0[`UOP_ROB], bru_rob, tail);
  wire infl1_bru = bru_flush && in_range(alloc_uop1[`UOP_ROB], bru_rob, tail);
  wire [2:0] inflight_wen = {2'b0, (alloc_r >= 2'd1) && alloc_uop0[`UOP_RD_WEN] && !infl0_bru}
                          + {2'b0, (alloc_r >= 2'd2) && alloc_uop1[`UOP_RD_WEN] && !infl1_bru};

  // 在飞裸窗的 era 修正（n49 实证死锁根因）：中断在"头项刚分配、内容 T+1
  // 沿才写"的窗口拍触发（ROB 刚被 ertn/例外清空后最易撞上），此时
  // e_pc[head] 是旧代残留 → exc_era 写错 → ertn 恢复到错误 pc 跑飞。
  // 头项在飞（本拍沿正写入）时 era 取在飞 uop 自带的 pc。
  // head_exc 不可能与在飞头共存（done 项不可能是本拍新分配），mux 安全。
  wire        head_infl0 = (alloc_r >= 2'd1) && (alloc_uop0[`UOP_ROB] == head);
  wire        head_infl1 = (alloc_r >= 2'd2) && (alloc_uop1[`UOP_ROB] == head);
  wire [31:0] head_pc_cur = head_infl0 ? alloc_uop0[`UOP_PC] :
                            head_infl1 ? alloc_uop1[`UOP_PC] : e_pc[head];

  // ---------------- 时序 ----------------
  integer ai;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      head         <= 5'd0;
      tail         <= 5'd0;
      count        <= 6'd0;
      exc_active   <= 1'b0;
      exc_code     <= 6'd0;
      exc_era      <= 32'd0;
      exc_badv     <= 32'd0;
      exc_redirect <= 1'b0;
      redirect_pc  <= 32'd0;
      flush_wen_cnt<= 6'd0;
      alloc_r      <= 2'd0;
      alloc_pdold0_r <= 6'd0;
      alloc_pdold1_r <= 6'd0;
      for (ai = 0; ai < 32; ai = ai + 1) begin
        e_done[ai]  <= 1'b0;
        e_excpt[ai] <= 6'd0;
      end
    end else begin
      // ---- 分配打拍（T 沿锁存，T+1 沿写项）----
      // do_exc/ertn/bru_flush 拍上游 rename 已取消分配（alloc=0），自愈清零
      alloc_r        <= alloc;
      alloc_pdold0_r <= alloc_pdold0;
      alloc_pdold1_r <= alloc_pdold1;

      // ---- 写回 x4（独立于指针更新；与分配不可能同项） ----
      if (wb0_valid) begin
        e_done[wb0_rob]  <= 1'b1;
        e_wdata[wb0_rob] <= wb0_wdata;
        e_excpt[wb0_rob] <= e_excpt[wb0_rob] | wb0_excpt;
        e_badv[wb0_rob]  <= wb0_badv;
      end
      if (wb1_valid) begin
        e_done[wb1_rob]  <= 1'b1;
        e_wdata[wb1_rob] <= wb1_wdata;
        e_excpt[wb1_rob] <= e_excpt[wb1_rob] | wb1_excpt;
        e_badv[wb1_rob]  <= wb1_badv;
      end
      if (wb2_valid) begin
        e_done[wb2_rob]  <= 1'b1;
        e_wdata[wb2_rob] <= wb2_wdata;
        e_excpt[wb2_rob] <= e_excpt[wb2_rob] | wb2_excpt;
        e_badv[wb2_rob]  <= wb2_badv;
      end
      if (wb3_valid) begin
        e_done[wb3_rob]  <= 1'b1;
        e_wdata[wb3_rob] <= wb3_wdata;
        e_excpt[wb3_rob] <= e_excpt[wb3_rob] | wb3_excpt;
        e_badv[wb3_rob]  <= wb3_badv;
      end

      // ---- 指针 / 例外状态 ----
      if (do_exc) begin
        // 例外/中断：不提交该指令，全机清尾，跳 EENTRY
        exc_redirect <= 1'b1;
        exc_code     <= head_exc ? e_excpt[head] : `EXCF_IS_INT;
        exc_era      <= head_pc_cur;
        exc_badv     <= (e_excpt[head] == `EXC_ADEF) ? e_pc[head]
                                                     : e_badv[head];
        exc_active   <= 1'b1;
        redirect_pc  <= eentry;
        tail         <= head;
        count        <= 6'd0;
        flush_wen_cnt<= exc_wen_cnt + {3'b0, inflight_wen};   // 锁存回收量（含在飞分配），供下一拍 exc_flush 使用
        // 集成修复（两阶段分配配套）：全窗清槽，防止槽位复用时旧
        // done/excpt 在内容写入前裸露一拍 → 伪例外/伪提交
        for (ai = 0; ai < 32; ai = ai + 1) begin
          e_done[ai]  <= 1'b0;
          e_excpt[ai] <= 6'd0;
          e_ertn[ai]  <= 1'b0;
          e_store[ai] <= 1'b0;
          e_wen[ai]   <= 1'b0;
        end
      end else if (ertn_cmt) begin
        // ERTN 提交：正常提交 + redirect 到 ERA，ROB 清空（C4 已排空）
        exc_redirect <= 1'b1;
        exc_active   <= 1'b0;
        redirect_pc  <= era_csr;
        head         <= h1;
        tail         <= h1;
        count        <= 6'd0;
        // 集成修复：与 do_exc 同理锁存回收量——窗口内可能有 ertn 之后
        // 分派的更年轻项（exc_flush 拍 rename 用此值回滚 freelist head，
        // 不锁存会用陈旧值导致 freelist 泄漏/重复释放）
        flush_wen_cnt<= exc_wen_cnt + {3'b0, inflight_wen};
        // 同 do_exc：全窗清槽防旧内容裸露
        for (ai = 0; ai < 32; ai = ai + 1) begin
          e_done[ai]  <= 1'b0;
          e_excpt[ai] <= 6'd0;
          e_ertn[ai]  <= 1'b0;
          e_store[ai] <= 1'b0;
          e_wen[ai]   <= 1'b0;
        end
      end else begin
        exc_redirect <= 1'b0;
        exc_active   <= 1'b0;   // 例外入口是单拍脉冲：不尽快拉低会每拍
                                // 抢占 csr_file 的 era/estat，覆盖 handler 的 csrwr
        if (bru_flush) begin
          // 误预测：老指令照常提交，tail 回滚到 bru_rob+1
          head  <= head + {3'd0, cmt_cnt};
          tail  <= bru_rob + 5'd1;
          count <= {1'b0, bru_cnt5};
          // 集成修复（两阶段分配配套）：清回滚区槽位——这些槽立刻会被
          // 重新分配，内容写入有一拍延迟，旧 done/excpt 不能裸露
          // （同拍 WB 写回更年轻项也被此清掉，正确：误路径结果作废）
          for (ai = 0; ai < 32; ai = ai + 1) begin
            if (in_range(ai[4:0], bru_rob, tail)) begin
              e_done[ai]  <= 1'b0;
              e_excpt[ai] <= 6'd0;
              e_ertn[ai]  <= 1'b0;
              e_store[ai] <= 1'b0;
              e_wen[ai]   <= 1'b0;
            end
          end
        end else begin
          // 项内容写入（T+1 沿）：alloc_r 与 alloc_uop* 同拍（都是 T 拍分派
          // 的 uop），索引用 uop 自带 UOP_ROB 标签；do_exc/ertn/bru_flush
          // 拍不进入本分支，误路径内容写自动取消
          if (alloc_r >= 2'd1) begin
            e_pc   [alloc_uop0[`UOP_ROB]] <= alloc_uop0[`UOP_PC];
            e_rd   [alloc_uop0[`UOP_ROB]] <= alloc_uop0[`UOP_RD_ARCH];
            e_pdnew[alloc_uop0[`UOP_ROB]] <= alloc_uop0[`UOP_PD];
            e_pdold[alloc_uop0[`UOP_ROB]] <= alloc_pdold0_r;
            e_wen  [alloc_uop0[`UOP_ROB]] <= alloc_uop0[`UOP_RD_WEN];
            e_store[alloc_uop0[`UOP_ROB]] <= u0_store;
            e_ertn [alloc_uop0[`UOP_ROB]] <= (alloc_uop0[`UOP_ALUOP] == `AOP_ERTN);
            e_done [alloc_uop0[`UOP_ROB]] <= 1'b0;
            e_excpt[alloc_uop0[`UOP_ROB]] <= alloc_uop0[`UOP_EXCPT];
            e_badv [alloc_uop0[`UOP_ROB]] <= 32'd0;
            e_wdata[alloc_uop0[`UOP_ROB]] <= 32'd0;
          end
          if (alloc_r >= 2'd2) begin
            e_pc   [alloc_uop1[`UOP_ROB]] <= alloc_uop1[`UOP_PC];
            e_rd   [alloc_uop1[`UOP_ROB]] <= alloc_uop1[`UOP_RD_ARCH];
            e_pdnew[alloc_uop1[`UOP_ROB]] <= alloc_uop1[`UOP_PD];
            e_pdold[alloc_uop1[`UOP_ROB]] <= alloc_pdold1_r;
            e_wen  [alloc_uop1[`UOP_ROB]] <= alloc_uop1[`UOP_RD_WEN];
            e_store[alloc_uop1[`UOP_ROB]] <= u1_store;
            e_ertn [alloc_uop1[`UOP_ROB]] <= (alloc_uop1[`UOP_ALUOP] == `AOP_ERTN);
            e_done [alloc_uop1[`UOP_ROB]] <= 1'b0;
            e_excpt[alloc_uop1[`UOP_ROB]] <= alloc_uop1[`UOP_EXCPT];
            e_badv [alloc_uop1[`UOP_ROB]] <= 32'd0;
            e_wdata[alloc_uop1[`UOP_ROB]] <= 32'd0;
          end
          // 指针前进仍由组合 alloc（T 拍）驱动：tail 与 rename 打的
          // UOP_ROB 标签同步，count 即时反映占用
          head  <= head + {3'd0, cmt_cnt};
          tail  <= tail + {3'd0, alloc};
          count <= count + {4'd0, alloc} - {4'd0, cmt_cnt};
          // 两阶段分配裸窗修复（func_test 实证死锁根因）：tail 推进当拍
          // 即清新槽控制位——内容写入在 T+1，若不清，旧代残留的
          // done=1 会在 count=1 的第一拍被提交逻辑看见 → 伪提交
          // （头部被跳过、bru_flush 错乱、IQ 僵尸死锁）。
          // 被清槽必为空闲槽（tail 前），不与同拍 WB 冲突。
          if (alloc >= 2'd1) begin
            e_done [tail]        <= 1'b0;
            e_excpt[tail]        <= 6'd0;
            e_ertn [tail]        <= 1'b0;
            e_store[tail]        <= 1'b0;
            e_wen  [tail]        <= 1'b0;
          end
          if (alloc >= 2'd2) begin
            // tail1 显式 5bit 截断（tail=31 回绕 0）：索引表达式按 32bit
            // integer 求值时 31+1=32 越界写被丢弃（iverilog v11 实测），
            // 陈旧 e_done 残留=伪提交温床；显式截断后仿真器间一致
            e_done [tail1]       <= 1'b0;
            e_excpt[tail1]       <= 6'd0;
            e_ertn [tail1]       <= 1'b0;
            e_store[tail1]       <= 1'b0;
            e_wen  [tail1]       <= 1'b0;
          end
        end
      end
    end
  end

endmodule
