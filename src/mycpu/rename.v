// ============================================================================
// rename.v — 双路重命名（fRAT + rRAT + 8 深分支 checkpoint）
//
// 时序协议（RN 为一级流水寄存器）：
//   T 拍：dec0/dec1 有效且资源够（!rob_full && !iq_almost && freelist 够 &&
//         分支时 checkpoint 够）→ 组合置 rob_alloc/fl_alloc/pdold*， freelist
//         与 ROB 在 T→T+1 沿更新；同沿锁存 uop0/uop1/uop_valid，rn_stall<=0。
//   资源不够：不分配，uop_valid<=0（插气泡），rn_stall<=1，ID 保持 dec 不变。
//   bru_flush / exc_flush 拍：取消分配，uop_valid<=0，rn_stall<=0。
//   约定：dec1 有效则 dec0 必有效（ID 保序双取）。
//
// checkpoint（8 槽循环分配 + 4bit seq 判龄）：
//   分派分支时快照 {fRAT(192b, 含本分支自身重命名), freelist head(含本分支
//   自身分配), rob_tail}，槽号写入 uop CKPT 字段。
//   bru_done/bru_done_ckpt：分支预测正确 → 释放该槽。
//   bru_flush/bru_ckpt：fRAT←快照，freelist head 回滚（fl_rollback*），
//   释放该槽及所有更年轻槽（seq 差 1..8 判年轻）。
// 例外恢复：exc_flush 拍 fRAT←rRAT 整体拷贝，所有 checkpoint 作废；
//   freelist head 回滚量 = ROB 窗口内未提交写目的项数（flush_wen_cnt），
//   等效 SPEC §4.1 的逐条回收，O(1) 完成。
// bundle 内 RAW/WAW：dec1 源命中 dec0 新目的 → 用 fl_pd0 且 RDY=0；
//   dec1 与 dec0 同目的（WAW）→ pdold1 = fl_pd0（防双释放）。
// ============================================================================
`include "la32_defs.vh"

module rename(
  input        clk,
  input        rst_n,
  input  [`DEC_W-1:0] dec0,
  input  [`DEC_W-1:0] dec1,
  output reg   rn_stall,
  output reg [`UOP_W-1:0] uop0,
  output reg [`UOP_W-1:0] uop1,
  output reg [1:0] uop_valid,
  // ROB 分配
  input        rob_full,
  input  [4:0] rob_tail0,
  input  [4:0] rob_tail1,
  output reg [1:0] rob_alloc,
  output reg [5:0] pdold0,
  output reg [5:0] pdold1,
  // freelist
  input        fl_empty0,
  input        fl_empty1,
  input  [5:0] fl_pd0,
  input  [5:0] fl_pd1,
  input  [5:0] fl_head,
  output reg [1:0] fl_alloc,
  output reg       fl_rollback,
  output reg [5:0] fl_rollback_head,
  // 例外时 ROB 内未提交写目的项数（freelist 回收量）
  input  [5:0] exc_reclaim_cnt,
  // 提交（更新 rRAT）
  input        cmt0_valid,
  input        cmt0_wen,
  input  [4:0] cmt0_rd,
  input  [5:0] cmt0_pdnew,
  input        cmt1_valid,
  input        cmt1_wen,
  input  [4:0] cmt1_rd,
  input  [5:0] cmt1_pdnew,
  // 分支 checkpoint
  input        bru_flush,
  input  [2:0] bru_ckpt,
  input        bru_done,          // 分支预测正确，释放槽
  input  [2:0] bru_done_ckpt,
  output       ckpt_full,
  // 例外恢复
  input        exc_flush,
  // ROB 例外检测拍（exc_redirect 前一拍）：当拍禁止分派，防分配泄漏
  input        rob_exc_pending,
  input        rob_empty,      // C4b：ROB 排空（serial 已提交/冲掉），解除分派封锁
  output [1:0] rn_pop,         // 本拍组合消费的 dec 条数（前端同拍弹 FIFO）
  // IQ 反压（几乎满则不再分派）
  input        iq_almost,
  // PRF ready 向量（决定 pj/pk 的 RDY 初值）
  input  [63:0] prf_ready
);

  // ---------------- fRAT / rRAT ----------------
  reg [5:0] frat [0:31];
  reg [5:0] rrat [0:31];

  // ---------------- checkpoint ----------------
  reg [191:0] ck_rat  [0:7];
  reg [5:0]   ck_head [0:7];
  /* verilator lint_off UNUSEDSIGNAL */  // rob tail 快照：SPEC §4.1 要求存，v1 未消费
  reg [4:0]   ck_rob  [0:7];
  /* verilator lint_on UNUSEDSIGNAL */
  reg [3:0]   ck_seq  [0:7];
  reg [7:0]   ck_valid;
  // 【ckpt 槽分配修复】原设计 ck_wptr mod-8 循环递增分配，但槽的释放
  // （bru_done 解析正确 / bru_flush 回收）与分配顺序无关——老分支若在 IQ
  // 久等操作数（100+ 拍），期间 8 个年轻分支完成分配，wptr 绕圈回到老
  // 分支仍占用的槽并直接覆盖快照（perf 实测：分支 tag=1 占槽 0 未解析，
  // tag=19 分配覆盖槽 0 → tag=19 的 bru_done 误释放槽 0；tag=1 之后
  // mispredict 用槽 0 恢复了被污染的快照 frat[r25]=23 → 幽灵映射 →
  // 依赖者等 ready 死锁）。
  // 修复：分配改为空闲优先编码，永不覆盖有效槽；ck_ok（nvalid<8/<7）
  // 保证必有空槽。
  reg [2:0]   ck_free0, ck_free1;
  reg         ck_free0_v;
  integer     fi;
  always @* begin
    ck_free0   = 3'd0;
    ck_free1   = 3'd0;
    ck_free0_v = 1'b0;
    for (fi = 7; fi >= 0; fi = fi - 1)
      if (!ck_valid[fi]) begin
        ck_free1   = ck_free0;
        ck_free0   = fi[2:0];
        ck_free0_v = 1'b1;
      end
  end
  reg [3:0]   seq_ctr;
  reg         serial_pend;   // C4b：ROB 中有未完成 serial，封锁后续分派

  // ---------------- dec 字段拆解 ----------------
  wire       d0_v    = dec0[`DEC_VALID];
  wire       d1_v    = dec1[`DEC_VALID];
  wire [4:0] d0_rj   = dec0[`DEC_RJ];
  wire [4:0] d0_rk   = dec0[`DEC_RK];
  wire [4:0] d0_rd   = dec0[`DEC_RD];
  wire [4:0] d1_rj   = dec1[`DEC_RJ];
  wire [4:0] d1_rk   = dec1[`DEC_RK];
  wire [4:0] d1_rd   = dec1[`DEC_RD];
  wire       d0_urj  = dec0[`DEC_USE_RJ];
  wire       d0_urk  = dec0[`DEC_USE_RK];
  wire       d1_urj  = dec1[`DEC_USE_RJ];
  wire       d1_urk  = dec1[`DEC_USE_RK];

  // C4b：serial 后的分派封锁——serial（csrwr/syscall/ertn/idle）一旦被分派，
  // 其后续指令一律不得再分派，直到它离开 ROB。否则 burst 前端跑得太快时，
  // serial 发射（serial_lock 冻结全队列）后 ROB 里残留未发射的年轻指令，
  // ROB 永远排不空 → 死锁（t5 根因）。封锁后任何 bru_flush 必来自更老分支，
  // 若 serial 在误路径上必被同拍杀死，可直接清锁。
  wire d0_serial = d0_v && dec0[`DEC_SERIAL];
  wire d1_serial = d1_v && dec1[`DEC_SERIAL];
  // serial 位于 dec0 时本拍只消费 dec0（dec1 留待下拍），保证 serial 是
  // 该 bundle 最年轻者——ROB 中 serial 之后没有任何东西
  wire d1_gv     = d1_v && !d0_serial;

  // 需要分配新物理号（写 r0 不分配，RD_WEN 清 0）
  wire need0 = d0_v && dec0[`DEC_RD_WEN] && (d0_rd != 5'd0);
  wire need1 = d1_gv && dec1[`DEC_RD_WEN] && (d1_rd != 5'd0);
  wire wen0  = dec0[`DEC_RD_WEN] && (d0_rd != 5'd0);
  wire wen1  = dec1[`DEC_RD_WEN] && (d1_rd != 5'd0);

  wire is_br0 = d0_v && (dec0[`DEC_BRTYPE] != `BR_NONE);
  wire is_br1 = d1_gv && (dec1[`DEC_BRTYPE] != `BR_NONE);

  wire [1:0] alloc_cnt = {1'b0, need0} + {1'b0, need1};
  wire [1:0] br_cnt    = {1'b0, is_br0} + {1'b0, is_br1};

  // dec1 用的新物理号（dec0 先取 fl_pd0）
  wire [5:0] pd1_new = need0 ? fl_pd1 : fl_pd0;

  // bundle 内 RAW/WAW
  wire hit0_j1 = need0 && (d0_rd == d1_rj);
  wire hit0_k1 = need0 && (d0_rd == d1_rk);
  wire hit0_d1 = need0 && (d0_rd == d1_rd);   // dec1 读/写同 rd
  wire waw01   = need0 && need1 && (d0_rd == d1_rd);

  // ---------------- checkpoint 占用（组合） ----------------
  integer ci;
  reg [3:0] ck_nvalid;
  always @* begin
    ck_nvalid = 4'd0;
    for (ci = 0; ci < 8; ci = ci + 1)
      ck_nvalid = ck_nvalid + {3'd0, ck_valid[ci]};
  end
  assign ckpt_full = &ck_valid;

  // 判龄：seq 差（mod 16）落在 1..8 为更年轻（最多 8 槽有效，无歧义）
  integer yi;
  reg [7:0] younger_mask;
  reg [3:0] seq_diff;
  always @* begin
    for (yi = 0; yi < 8; yi = yi + 1) begin
      seq_diff = ck_seq[yi] - ck_seq[bru_ckpt];
      younger_mask[yi] = ck_valid[yi] && (seq_diff != 4'd0) &&
                         (seq_diff <= 4'd8);
    end
  end

  // ---------------- 分派条件 ----------------
  wire fl_ok = (alloc_cnt == 2'd0) ? 1'b1 :
               (alloc_cnt == 2'd1) ? !fl_empty0 : !fl_empty1;
  wire ck_ok = (br_cnt == 2'd0) ? 1'b1 :
               (br_cnt == 2'd1) ? (ck_nvalid < 4'd8) : (ck_nvalid < 4'd7);

  wire dispatch = (d0_v || d1_gv) && !rob_full && !iq_almost &&
                  fl_ok && ck_ok && !bru_flush && !exc_flush &&
                  !rob_exc_pending && !serial_pend;

  // 同拍消费握手（修前端重复弹/丢指令）：前端按本拍真实消费数弹 FIFO，
  // 不再依赖寄存器化 rn_stall（其在 disp 1->0 时晚一拍导致丢指令，
  // 0->1 时前端晚一拍弹导致同一 dec 被重复分派）。
  assign rn_pop = dispatch ? ({1'b0, d0_v} + {1'b0, d1_gv}) : 2'd0;

  // ---------------- 组合输出 ----------------
  always @* begin
    rob_alloc = dispatch ? ({1'b0, d0_v} + {1'b0, d1_gv}) : 2'd0;
    fl_alloc  = dispatch ? alloc_cnt : 2'd0;
    pdold0    = frat[d0_rd];
    pdold1    = waw01 ? fl_pd0 : frat[d1_rd];
    fl_rollback      = bru_flush || exc_flush;
    fl_rollback_head = exc_flush ? (fl_head - exc_reclaim_cnt)
                                 : ck_head[bru_ckpt];
  end

  // 第二分支槽号（空闲优先编码：br0 取最低空槽，br1 取次低/最低）
  wire [2:0] ck_slot1 = is_br0 ? ck_free1 : ck_free0;

  // ---------------- fRAT 快照（含本拍重命名） ----------------
  integer si;
  reg [191:0] rat_after0, rat_after1;
  always @* begin
    for (si = 0; si < 32; si = si + 1)
      rat_after0[6*si +: 6] = frat[si];
    if (need0) rat_after0[6*d0_rd +: 6] = fl_pd0;
    rat_after1 = rat_after0;
    if (need1) rat_after1[6*d1_rd +: 6] = pd1_new;
  end

  // ---------------- uop 组装（组合，分配沿锁存） ----------------
  // t4 根因修复：clr_rdy 由"上拍分派的寄存器化 uop"驱动，本拍末才生效；
  // 而本拍正在重命名的消费者同拍采样 prf_ready 会看到 stale ready=1
  // （frat 已指向新 pd，但 ready 尚未拉低）→ 提前发射读旧值。
  // ALU→ALU 被 PRF 同拍写读直通掩盖，MDU/LSU 等多拍生产者必现。
  // 修复：采样 rdy 时同拍扣除"本拍将被 clr 的 pd"（即上拍分派 uop 的目的）。
  wire        pclr0   = uop_valid[0] & uop0[`UOP_RD_WEN] & (uop0[`UOP_PD] != 6'd0);
  wire        pclr1   = uop_valid[1] & uop1[`UOP_RD_WEN] & (uop1[`UOP_PD] != 6'd0);
  wire [5:0]  pclr_pd0 = uop0[`UOP_PD];
  wire [5:0]  pclr_pd1 = uop1[`UOP_PD];
  wire [5:0]  pj0_map = frat[d0_rj];
  wire [5:0]  pk0_map = frat[d0_rk];
  wire [5:0]  pj1_map = hit0_j1 ? fl_pd0 : frat[d1_rj];
  wire [5:0]  pk1_map = hit0_k1 ? fl_pd0 : frat[d1_rk];
  wire        pj0_pclr = (pclr0 & (pclr_pd0 == pj0_map)) | (pclr1 & (pclr_pd1 == pj0_map));
  wire        pk0_pclr = (pclr0 & (pclr_pd0 == pk0_map)) | (pclr1 & (pclr_pd1 == pk0_map));
  wire        pj1_pclr = (pclr0 & (pclr_pd0 == pj1_map)) | (pclr1 & (pclr_pd1 == pj1_map));
  wire        pk1_pclr = (pclr0 & (pclr_pd0 == pk1_map)) | (pclr1 & (pclr_pd1 == pk1_map));

  reg [`UOP_W-1:0] uop0_c, uop1_c;
  always @* begin
    uop0_c = {`UOP_W{1'b0}};
    uop0_c[`UOP_PC]      = dec0[`DEC_PC];
    uop0_c[`UOP_IMM]     = dec0[`DEC_IMM];
    uop0_c[`UOP_ALUOP]   = dec0[`DEC_ALUOP];
    uop0_c[`UOP_FU]      = dec0[`DEC_FU];
    uop0_c[`UOP_PD]      = need0 ? fl_pd0 : frat[d0_rd];
    uop0_c[`UOP_PJ]      = pj0_map;
    uop0_c[`UOP_PK]      = pk0_map;
    uop0_c[`UOP_PJ_RDY]  = !d0_urj || (prf_ready[pj0_map] & ~pj0_pclr);
    uop0_c[`UOP_PK_RDY]  = !d0_urk || (prf_ready[pk0_map] & ~pk0_pclr);
    uop0_c[`UOP_RD_WEN]  = wen0;
    uop0_c[`UOP_RD_ARCH] = d0_rd;
    uop0_c[`UOP_SERIAL]  = dec0[`DEC_SERIAL];
    uop0_c[`UOP_BR_TYPE] = dec0[`DEC_BRTYPE];
    uop0_c[`UOP_ROB]     = rob_tail0;
    uop0_c[`UOP_CKPT]    = is_br0 ? ck_free0 : `CKPT_INVALID;
    uop0_c[`UOP_EXCPT]   = dec0[`DEC_EXCPT];
    uop0_c[`UOP_USE_IMM] = !d0_urk;
    uop0_c[`UOP_PRED_TAKEN]  = dec0[`DEC_PRED_TAKEN];
    uop0_c[`UOP_PRED_TARGET] = dec0[`DEC_PRED_TARGET];
    uop0_c[`UOP_BR_CAT]      = dec0[`DEC_BR_CAT];

    uop1_c = {`UOP_W{1'b0}};
    uop1_c[`UOP_PC]      = dec1[`DEC_PC];
    uop1_c[`UOP_IMM]     = dec1[`DEC_IMM];
    uop1_c[`UOP_ALUOP]   = dec1[`DEC_ALUOP];
    uop1_c[`UOP_FU]      = dec1[`DEC_FU];
    uop1_c[`UOP_PD]      = need1 ? pd1_new :
                           (hit0_d1 ? fl_pd0 : frat[d1_rd]);
    uop1_c[`UOP_PJ]      = pj1_map;
    uop1_c[`UOP_PK]      = pk1_map;
    uop1_c[`UOP_PJ_RDY]  = !d1_urj ? 1'b1 :
                           hit0_j1 ? 1'b0  : (prf_ready[pj1_map] & ~pj1_pclr);
    uop1_c[`UOP_PK_RDY]  = !d1_urk ? 1'b1 :
                           hit0_k1 ? 1'b0  : (prf_ready[pk1_map] & ~pk1_pclr);
    uop1_c[`UOP_RD_WEN]  = wen1;
    uop1_c[`UOP_RD_ARCH] = d1_rd;
    uop1_c[`UOP_SERIAL]  = dec1[`DEC_SERIAL];
    uop1_c[`UOP_BR_TYPE] = dec1[`DEC_BRTYPE];
    uop1_c[`UOP_ROB]     = rob_tail1;
    uop1_c[`UOP_CKPT]    = is_br1 ? ck_slot1 : `CKPT_INVALID;
    uop1_c[`UOP_EXCPT]   = dec1[`DEC_EXCPT];
    uop1_c[`UOP_USE_IMM] = !d1_urk;
    uop1_c[`UOP_PRED_TAKEN]  = dec1[`DEC_PRED_TAKEN];
    uop1_c[`UOP_PRED_TARGET] = dec1[`DEC_PRED_TARGET];
    uop1_c[`UOP_BR_CAT]      = dec1[`DEC_BR_CAT];
  end

  // ---------------- 时序 ----------------
  integer ri;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ri = 0; ri < 32; ri = ri + 1) begin
        frat[ri] <= ri[5:0];
        rrat[ri] <= ri[5:0];
      end
      ck_valid  <= 8'd0;
      seq_ctr   <= 4'd0;
      serial_pend <= 1'b0;
      rn_stall  <= 1'b0;
      uop_valid <= 2'b00;
      uop0      <= {`UOP_W{1'b0}};
      uop1      <= {`UOP_W{1'b0}};
    end else begin
      // ---- rRAT：提交维护（例外恢复的数据源），cmt1 较新后写 ----
      if (cmt0_valid && cmt0_wen && (cmt0_rd != 5'd0))
        rrat[cmt0_rd] <= cmt0_pdnew;
      if (cmt1_valid && cmt1_wen && (cmt1_rd != 5'd0))
        rrat[cmt1_rd] <= cmt1_pdnew;

      // ---- fRAT：例外 > 分支恢复 > 正常分派 ----
      if (exc_flush) begin
        for (ri = 0; ri < 32; ri = ri + 1)
          frat[ri] <= rrat[ri];
      end else if (bru_flush) begin
        for (ri = 0; ri < 32; ri = ri + 1)
          frat[ri] <= ck_rat[bru_ckpt][6*ri +: 6];
      end else if (dispatch) begin
        if (need0) frat[d0_rd] <= fl_pd0;
        if (need1) frat[d1_rd] <= pd1_new;   // WAW 时后写覆盖
      end

      // ---- checkpoint 槽有效位 ----
      for (ri = 0; ri < 8; ri = ri + 1) begin
        if (exc_flush)
          ck_valid[ri] <= 1'b0;
        else if (bru_flush &&
                 ((ri[2:0] == bru_ckpt) || younger_mask[ri]))
          ck_valid[ri] <= 1'b0;
        else if (!bru_flush && bru_done && (ri[2:0] == bru_done_ckpt))
          ck_valid[ri] <= 1'b0;
        else if (dispatch &&
                 ((is_br0 && (ri[2:0] == ck_free0)) ||
                  (is_br1 && (ri[2:0] == ck_slot1))))
          ck_valid[ri] <= 1'b1;
      end

      // ---- checkpoint 数据 + 分配指针 ----
      if (dispatch && is_br0) begin
        ck_rat[ck_free0]  <= rat_after0;
        ck_head[ck_free0] <= fl_head + {5'd0, need0}; // dec0 自身分配之后
        ck_rob[ck_free0]  <= rob_tail0;
        ck_seq[ck_free0]  <= seq_ctr;
      end
      if (dispatch && is_br1) begin
        ck_rat[ck_slot1]  <= rat_after1;
        ck_head[ck_slot1] <= fl_head + {4'd0, alloc_cnt}; // 本 bundle 分配后
        ck_rob[ck_slot1]  <= rob_tail1;
        ck_seq[ck_slot1]  <= seq_ctr + {3'd0, is_br0};
      end
      if (dispatch && (br_cnt != 2'd0))
        seq_ctr <= seq_ctr + {2'd0, br_cnt};

      // ---- C4b serial 封锁锁存 ----
      // set 优先于 clear：ROB 排空拍恰好分派新 serial（例外返回后第一条），
      // 若 clear 优先则锁存丢失，年轻指令涌入 → serial_lock 死锁（t5 实测）。
      // dispatch 已含 !bru_flush && !exc_flush，set/clear 不会真冲突。
      if (dispatch && (d0_serial || (d1_gv && d1_serial)))
        serial_pend <= 1'b1;
      else if (exc_flush || bru_flush || rob_empty)
        serial_pend <= 1'b0;

      // ---- uop 寄存器 / 反压 ----
      if (exc_flush || bru_flush) begin
        uop_valid <= 2'b00;
        rn_stall  <= 1'b0;
      end else begin
        rn_stall <= (d0_v || d1_v) && !dispatch;
        if (dispatch) begin
          uop0      <= uop0_c;
          uop1      <= uop1_c;
          uop_valid <= {d1_gv, d0_v};
        end else begin
          uop_valid <= 2'b00;
        end
      end
    end
  end

endmodule
