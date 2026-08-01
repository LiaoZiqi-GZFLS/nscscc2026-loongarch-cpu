// ============================================================================
// issue_queue.v — 12 项发射队列（年龄矩阵 oldest-ready 选择）
// SPEC §4.3 / §3：双发射，lane0 任意 FU，lane1 仅 FU_ALU
//   C1: lane1 候选 pj/pk == lane0 候选 pd（且 lane0 写目的）→ 本拍只发 lane0
//   C3: FU_MDU && mdu_busy → 该候选跳过
//   C4: SERIAL 项 → 需 rob_empty 且自身为全队列最老有效项
//   C6: FU_LSU load && lsu_block_load → 该候选跳过
// 唤醒：项内 RDY 位（被广播置位后锁存）| 单拍类 bcast0/1 | prf_ready 轮询
// flush：bru_flush 杀 (bru_rob, rob_tail_cur) 环形开区间；exc_flush 全清
// ============================================================================
`include "la32_defs.vh"

module issue_queue(
  input clk, input rst_n,
  input [1:0] enq,                               // bit0: enq_uop0 有效, bit1: enq_uop1 有效
  input [`UOP_W-1:0] enq_uop0, input [`UOP_W-1:0] enq_uop1,
  output full, output almost_full,               // almost_full: 剩余 <2（含在途 enq）
  input [1:0] enq_inflight,                      // 本拍末将写入的在途 uop 数（rename 寄存器级）
  // 唤醒广播（单拍类 EX 完成）
  input bcast0_valid, input [5:0] bcast0_pd,
  input bcast1_valid, input [5:0] bcast1_pd,
  input [63:0] prf_ready,                        // 多拍类保守唤醒
  // 发射输出（寄存器化）
  output reg issue0_valid, output reg [`UOP_W-1:0] issue0_uop,   // lane0 任意 FU
  output reg issue1_valid, output reg [`UOP_W-1:0] issue1_uop,   // lane1 仅 FU_ALU
  // 结构信号
  input mdu_busy,                                // C3（含上拍发射的 MDU，cpu_core 侧已合成）
  input lsu_block_load,                          // 保留端口（C6 已精确化，不再使用）
  input lsu_struct,                              // LSU 结构冒险（store 用，含 sb 满）
  input lsu_struct_ld,                           // LSU 结构冒险（load 用，不含 sb 满）
  input [3:0]  sb_v,                             // C6 精确化：store buffer 有效位
  input [3:0]  sb_g,                             // C6 补洞：store buffer 各项已提交授权位
  input [19:0] sb_tags,                          // C6 精确化：store buffer 各项 ROB 标签（拍平）
  input rob_empty,                               // C4 串行点解锁信号
  input [4:0] rob_head_tag,                      // C4：serial 项须位于 ROB 头
  // flush
  input bru_flush, input [4:0] bru_rob, input [4:0] rob_tail_cur,
  input rob_full,                                // ROB 满时 tail==head，环形差恒 0
  input exc_flush
);

  localparam N = `IQ_DEPTH;                      // 12

  // ---------------- 存储 ----------------
  reg [`UOP_W-1:0] entry_uop [0:N-1];
  reg [N-1:0]      valid;
  // 年龄矩阵: age[i][j]==1 表示项 i 比项 j 老（对角线恒 1）
  reg [N-1:0]      age [0:N-1];

  integer i_rdy, i_oldest, i_elig, i_s0, i_s0u, i_s1, i_s1u, i_sb;
  integer i_free, i_enc, i_kill;
  integer i_seq, j_seq;

  // ---------------- 每拍组合：ready 判定 ----------------
  // 项内 RDY 位 | bcast 命中 | prf_ready 轮询
  reg [N-1:0] pj_rdy, pk_rdy, rdy;
  always @(*) begin
    for (i_rdy = 0; i_rdy < N; i_rdy = i_rdy + 1) begin
      pj_rdy[i_rdy] = entry_uop[i_rdy][`UOP_PJ_RDY]
                | (bcast0_valid & (bcast0_pd == entry_uop[i_rdy][`UOP_PJ]))
                | (bcast1_valid & (bcast1_pd == entry_uop[i_rdy][`UOP_PJ]))
                | prf_ready[entry_uop[i_rdy][`UOP_PJ]];
      pk_rdy[i_rdy] = entry_uop[i_rdy][`UOP_PK_RDY]
                | (bcast0_valid & (bcast0_pd == entry_uop[i_rdy][`UOP_PK]))
                | (bcast1_valid & (bcast1_pd == entry_uop[i_rdy][`UOP_PK]))
                | prf_ready[entry_uop[i_rdy][`UOP_PK]];
      rdy[i_rdy]    = pj_rdy[i_rdy] & pk_rdy[i_rdy];
    end
  end

  // ---------------- 全队列最老有效项（C4 用） ----------------
  reg [N-1:0] oldest_valid;
  always @(*) begin
    for (i_oldest = 0; i_oldest < N; i_oldest = i_oldest + 1)
      oldest_valid[i_oldest] = valid[i_oldest] & (&(~valid | age[i_oldest]));
  end

  // ---------------- bru_flush 杀伤区间: (bru_rob, rob_tail_cur) 环形开区间 ----------------
  // t 在区间内 <=> (t - bru_rob - 1) < (rob_tail_cur - bru_rob - 1)  （mod 32）
  // （声明在 elig 之前：选择逻辑同拍引用，iverilog 要求先声明）
  reg [N-1:0] kill;
  always @(*) begin
    for (i_kill = 0; i_kill < N; i_kill = i_kill + 1)
      kill[i_kill] = bru_flush & valid[i_kill] &
                ((entry_uop[i_kill][`UOP_ROB] - bru_rob - 5'd1)
                 < (rob_tail_cur - bru_rob - 5'd1));
  end

  // ---------------- 发射资格（slot0 候选） ----------------
  // load 类 ALUOP: LDB..LDHU(24-28), LL(32)
  reg serial_lock;                                 // C4 冻结（定义见 slot0 之后）
  reg [N-1:0] elig0;
  always @(*) begin
    for (i_elig = 0; i_elig < N; i_elig = i_elig + 1) begin
      elig0[i_elig] = valid[i_elig] & rdy[i_elig];
      // flush 同拍：将被杀/全清的项不得参与选择——发射输出是寄存器化的，
      // flush 拍选出的死项会在下一拍呈现执行（鬼指令二次 bru_flush 错乱）
      if (kill[i_elig] || exc_flush)
        elig0[i_elig] = 1'b0;
      // C3: MDU 结构冒险
      if (entry_uop[i_elig][`UOP_FU] == `FU_MDU && mdu_busy)
        elig0[i_elig] = 1'b0;
      // LSU 结构冒险：发射寄存器化有一拍延迟，LSU busy 来不及反馈，
      // 必须由 cpu_core 合成 lsu_struct（noaccept | 上拍发射了 LSU）提前门控，
      // 否则背对背 LSU 访存会在 LSU 非 IDLE 拍被丢弃（ROB 永不 done 死锁）
      // load 不占 store buffer，不应被 sb 满阻塞——否则"sb 满是未提交投机
      // store + ROB 头是 load"死锁（n13 实证）：load 发不出 → store 无法提交
      // 授权 → sb 永不排空。load 与更老 sb store 的序由下方 C6 独立保证。
      if (entry_uop[i_elig][`UOP_FU] == `FU_LSU &&
          (((entry_uop[i_elig][`UOP_ALUOP] >= `AOP_LDB && entry_uop[i_elig][`UOP_ALUOP] <= `AOP_LDHU)
            || entry_uop[i_elig][`UOP_ALUOP] == `AOP_LL)
             ? lsu_struct_ld : lsu_struct))
        elig0[i_elig] = 1'b0;
      // C6（精确化）：load 仅被 store buffer 中"比它老"的 store 阻塞——
      // 年龄比较用 ROB 环形偏移：(sb_tag-head) < (load_tag-head) 即更老。
      // 若阻塞条件含更年轻的 store：乱序发射下年轻 store 先入 sb，
      // 老 load 被 C6 挡住，年轻 store 又排在 load 之后无法提交排空 → 死锁
      if (entry_uop[i_elig][`UOP_FU] == `FU_LSU &&
          ((entry_uop[i_elig][`UOP_ALUOP] >= `AOP_LDB && entry_uop[i_elig][`UOP_ALUOP] <= `AOP_LDHU)
           || entry_uop[i_elig][`UOP_ALUOP] == `AOP_LL)) begin
        // 年龄判定：pos(x)=(x-head) mod 32 是距头的环形位置；已提交 store
        // 的槽位在 head 之后（pos >= cnt），对 ROB 内任何 load 都是"更老"。
        // 唯一不阻塞的情形：store 仍在 ROB 内且比 load 年轻
        //   (pos_ld < pos_sb < cnt)。其余（含已提交、槽位复用）一律阻塞。
        // cnt 必须用真实 ROB 占用数：ROB 满时 tail==head，5bit 环形差得 0，
        // 会把所有 sb store 误判为"更老" → 头 load 被年轻投机 store 永久
        // 阻塞 → 死锁（n41 实证：ROB=32 满 + sb 满 4 项投机 store）。
        // 已提交（granted）store 必须无条件阻塞一切 load：提交按序，已提交
        // store 必然比 ROB 内任何 load 老；且 ROB 满时 cnt=32，刚提交的 store
        // 槽位 pos_sb=(tag-head) mod 32 可大至 31 < 32=cnt，会被误判为"ROB 内
        // 年轻 store"而放行 → load 先于更老 store 的 drain/invalidate 读 dcache
        // → 命中陈旧行/refill 抢在 W 前读到旧数据（板上 func 43/44 实证：
        // ld.bu 在 SB=1111 时被接受，与 st.w 的 W 握手 invalidate 同拍抢 tag）。
        for (i_sb = 0; i_sb < 4; i_sb = i_sb + 1)
          if (sb_v[i_sb] &&
              (sb_g[i_sb] ||
               !(((entry_uop[i_elig][`UOP_ROB] - rob_head_tag)
                    < (sb_tags[i_sb*5 +: 5] - rob_head_tag)) &&
                 ({1'b0, (sb_tags[i_sb*5 +: 5] - rob_head_tag)}
                    < (rob_full ? 6'd32 : {1'b0, (rob_tail_cur - rob_head_tag)})))))
            elig0[i_elig] = 1'b0;
      end
      // C4: 串行点须自身为 IQ 最老且位于 ROB 头（之前指令全提交）
      if (entry_uop[i_elig][`UOP_SERIAL] &&
          !(oldest_valid[i_elig] && (entry_uop[i_elig][`UOP_ROB] == rob_head_tag)))
        elig0[i_elig] = 1'b0;
      // C4 后半：serial 在飞期间全队列冻结（serial_lock）
      if (serial_lock)
        elig0[i_elig] = 1'b0;
    end
  end



  // slot0 = 最老 elig0（年龄矩阵仲裁：对所有其他 elig 项我都更老）
  reg [N-1:0] slot0_oh;
  always @(*) begin
    for (i_s0 = 0; i_s0 < N; i_s0 = i_s0 + 1)
      slot0_oh[i_s0] = elig0[i_s0] & (&(~elig0 | age[i_s0]));
  end
  wire slot0_fire = |slot0_oh;

  // slot0 的 uop（one-hot mux）
  reg [`UOP_W-1:0] slot0_uop;
  always @(*) begin
    slot0_uop = {`UOP_W{1'b0}};
    for (i_s0u = 0; i_s0u < N; i_s0u = i_s0u + 1)
      if (slot0_oh[i_s0u]) slot0_uop = slot0_uop | entry_uop[i_s0u];
  end

  // serial_lock：serial 项发射后置位，其提交（ROB 排空）后解除
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)            serial_lock <= 1'b0;
    else if (exc_flush)    serial_lock <= 1'b0;
    else if (rob_empty)    serial_lock <= 1'b0;
    else if (slot0_fire && slot0_uop[`UOP_SERIAL] && !bru_flush)
                           serial_lock <= 1'b1;
  end

  // ---------------- slot1 候选：次老 ready 且 FU==FU_ALU，排除 slot0 ----------------
  reg [N-1:0] elig1, slot1_oh;
  always @(*) begin
    for (i_s1 = 0; i_s1 < N; i_s1 = i_s1 + 1)
      elig1[i_s1] = elig0[i_s1] & ~slot0_oh[i_s1] & (entry_uop[i_s1][`UOP_FU] == `FU_ALU);
    for (i_s1 = 0; i_s1 < N; i_s1 = i_s1 + 1)
      slot1_oh[i_s1] = elig1[i_s1] & (&(~elig1 | age[i_s1]));
  end

  reg [`UOP_W-1:0] slot1_uop;
  always @(*) begin
    slot1_uop = {`UOP_W{1'b0}};
    for (i_s1u = 0; i_s1u < N; i_s1u = i_s1u + 1)
      if (slot1_oh[i_s1u]) slot1_uop = slot1_uop | entry_uop[i_s1u];
  end

  // C1: lane1 候选 pj/pk 命中 lane0 候选 pd（lane0 实际写目的时）→ 回退单发射
  wire c1_conflict = slot0_fire & slot0_uop[`UOP_RD_WEN] &
                     ((slot1_uop[`UOP_PJ] == slot0_uop[`UOP_PD]) |
                      (slot1_uop[`UOP_PK] == slot0_uop[`UOP_PD]));
  wire slot1_fire = slot0_fire & (|slot1_oh) & ~c1_conflict;

  // ---------------- 满/将满（组合统计） ----------------
  integer cnt_v;
  reg [4:0] nvalid;
  always @(*) begin
    nvalid = 5'd0;
    for (cnt_v = 0; cnt_v < N; cnt_v = cnt_v + 1)
      nvalid = nvalid + {4'd0, valid[cnt_v]};
  end
  assign full        = (nvalid >= N);
  // 剩余 <2 须计入在途 enq：rename 有寄存器级，dispatch(T) 的 uop 在 T+1 末才写入；
  // 若只看 nvalid，连续两拍双分派会在 IQ 满时被 enq0_fire 静默丢弃（t4 丢指令根因之二）
  assign almost_full = (nvalid + {3'b000, enq_inflight}) >= N-1;

  // ---------------- 出队后的空位（本拍出队项可同拍被新入队复用） ----------------
  reg [N-1:0] free_mask;
  always @(*) begin
    for (i_free = 0; i_free < N; i_free = i_free + 1)
      free_mask[i_free] = ~valid[i_free] | slot0_oh[i_free] | (slot1_oh[i_free] & slot1_fire);
  end

  // 优先编码器：free0/free1 = 最低两个空位号
  reg [3:0] free0, free1;
  reg       free0_found, free1_found;
  always @(*) begin
    free0 = 4'd0; free0_found = 1'b0;
    free1 = 4'd0; free1_found = 1'b0;
    for (i_enc = N-1; i_enc >= 0; i_enc = i_enc - 1)
      if (free_mask[i_enc]) begin free0 = i_enc[3:0]; free0_found = 1'b1; end
    for (i_enc = N-1; i_enc >= 0; i_enc = i_enc - 1)
      if (free_mask[i_enc] && !(free0_found && i_enc[3:0] == free0)) begin
        free1 = i_enc[3:0]; free1_found = 1'b1;
      end
  end

  // 入队请求（防御：enq[1] 单独有效时把 uop1 当第一条）
  wire enq0_fire = (enq[0] | enq[1]) & free0_found;
  wire enq1_fire = enq[0] & enq[1] & free0_found & free1_found;
  wire [`UOP_W-1:0] enq0_uop = enq[0] ? enq_uop0 : enq_uop1;

  // ---------------- 时序 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid        <= {N{1'b0}};
      issue0_valid <= 1'b0;
      issue1_valid <= 1'b0;
      issue0_uop   <= {`UOP_W{1'b0}};
      issue1_uop   <= {`UOP_W{1'b0}};
      for (i_seq = 0; i_seq < N; i_seq = i_seq + 1) begin
        age[i_seq]      <= {N{1'b1}};
        entry_uop[i_seq] <= {`UOP_W{1'b0}};
      end
    end else begin
      // 项内 RDY 位锁存广播/PRF 命中（单调置位）
      for (i_seq = 0; i_seq < N; i_seq = i_seq + 1) begin
        entry_uop[i_seq][`UOP_PJ_RDY] <= pj_rdy[i_seq];
        entry_uop[i_seq][`UOP_PK_RDY] <= pk_rdy[i_seq];
      end

      // 出队
      for (i_seq = 0; i_seq < N; i_seq = i_seq + 1)
        if (slot0_oh[i_seq] || (slot1_oh[i_seq] && slot1_fire))
          valid[i_seq] <= 1'b0;

      // 发射输出寄存器化
      issue0_valid <= slot0_fire;
      if (slot0_fire) issue0_uop <= slot0_uop;
      issue1_valid <= slot1_fire;
      if (slot1_fire) issue1_uop <= slot1_uop;

      // 入队：设置年龄——新项比所有现存有效项年轻；同拍两项 uop0 更老
      if (enq0_fire) begin
        valid[free0]     <= 1'b1;
        entry_uop[free0] <= enq0_uop;
        for (j_seq = 0; j_seq < N; j_seq = j_seq + 1) begin
          age[free0][j_seq] <= (j_seq[3:0] == free0);
          if (j_seq[3:0] != free0)
            age[j_seq][free0] <= valid[j_seq] & ~slot0_oh[j_seq] & ~(slot1_oh[j_seq] & slot1_fire);
        end
      end
      if (enq1_fire) begin
        valid[free1]     <= 1'b1;
        entry_uop[free1] <= enq_uop1;
        for (j_seq = 0; j_seq < N; j_seq = j_seq + 1) begin
          age[free1][j_seq] <= (j_seq[3:0] == free1);
          if (j_seq[3:0] != free1)
            age[j_seq][free1] <= valid[j_seq] & ~slot0_oh[j_seq] & ~(slot1_oh[j_seq] & slot1_fire);
        end
      end
      if (enq0_fire && enq1_fire) begin
        age[free0][free1] <= 1'b1;               // uop0 老
        age[free1][free0] <= 1'b0;
      end

      // flush（最高优先）
      if (exc_flush) begin
        valid        <= {N{1'b0}};
        issue0_valid <= 1'b0;
        issue1_valid <= 1'b0;
      end else if (bru_flush) begin
        for (i_seq = 0; i_seq < N; i_seq = i_seq + 1)
          if (kill[i_seq]) valid[i_seq] <= 1'b0;
      end
    end
  end

endmodule
