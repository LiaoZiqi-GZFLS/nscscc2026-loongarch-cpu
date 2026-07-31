// ============================================================================
// frontend.v — 取指前端 v2（icache 一拍一整行接口 + 8 深指令 FIFO + 双路组合译码）
// - 与 icache 的 req/resp 流水（1 拍延迟）：
//     req_addr = pc_reg 对齐 16B + inflight*16（下一个待发块）
//     req 条件: FIFO 余量预留（cnt + inflight*4 <= 4）且 !redirect 且 !ic_busy
//     resp_valid 拍：整行 4 条压 FIFO（首块按 skip_cnt 丢弃头部、补 first_low）
// - inflight 记账：req 发出 +1 / resp 收下 -1（同拍收发不变）；最多 1 个在途
//   未收块的 pc 关联 = pc_reg（resp 收下时才 +16，保证 pc_reg 恒指最早未完成块）
// - redirect：清 FIFO；pc_reg<=redirect_pc；skip=pc[3:2]，first_low=pc[1:0]；
//   在途 resp 作废（resp_kill），icache 在途 refill 完成拍到达后丢弃
// - PC[1:0]!=0 由 decoder 注入 EXC_ADEF（首有效字补 first_low 保留语义，n52）
// - v3 BPU 集成：req 拍组合查 bpu（BTB 行粒度+GShare+RAS）并打拍 bq_*_r——
//   hit 固定 1 拍、miss 时 ic_busy 冻结新 req，故单级打拍与 resp 严格对齐；
//   resp 拍 pred_fire（命中且预测 taken 且分支在取指窗口内）→ 行截断只压
//   offset+1 条、pc_reg<=预测目标（复用 skip 机制），同拍发出的旧流 req
//   用 resp_kill 作废；FIFO 每项携 pred_taken/pred_target 随 dec 注入，
//   由 EX BRU 验证（预测正确则 taken 不再 flush——核心收益）
// ============================================================================
`include "la32_defs.vh"

module frontend #(
  parameter BOOT_PC = 32'h1c000000
)(
  input                  clk,
  input                  rst_n,
  // icache req/resp 接口
  output      [31:0]     req_addr,
  output                 req_valid,
  input                  resp_valid,
  input       [127:0]    resp_line,
  input                  ic_busy,
  // 译码输出（每拍 ≤2 条）
  output      [`DEC_W-1:0] dec0,
  output      [`DEC_W-1:0] dec1,
  input                  rn_stall,   // 保留（调试观察）；弹出由 rn_pop 驱动
  input  [1:0]           rn_pop,
  // 重定向
  input                  redirect,
  input       [31:0]     redirect_pc,
  // BPU 更新（EX bru 解析拍，来自 cpu_core）
  input                  bpu_u_valid,
  input       [31:0]     bpu_u_pc,
  input       [1:0]      bpu_u_cat,
  input                  bpu_u_taken,
  input       [31:0]     bpu_u_target
);

  // ---------------- 取指状态 ----------------
  reg  [31:0] pc_reg;        // 最早未完成块的原始 PC（resp 收下后才 +16）
  reg  [1:0]  skip_cnt;      // 首块需丢弃的条数（redirect pc[3:2]）
  reg  [1:0]  first_low;     // 首块 pc[1:0]（redirect 非对齐目标 → ADEF，n52）
  reg         inflight;      // 有在途 req（发出未收）
  reg         resp_kill;     // redirect 作废的在途 resp

  // ---------------- 16 深指令 FIFO（移位实现，fifo[0] 为头；v2.7 由 8 加深，
  // 吸收 refill 抖动：停顿窗口多囤 2 行，恢复后双发射续航从 2 拍延到 4 拍） ----------------
  reg  [31:0] fifo_inst [0:15];
  reg  [31:0] fifo_pc   [0:15];
  reg         fifo_ptk  [0:15];   // v3：该条被预测 taken（仅分支）
  reg  [31:0] fifo_ptg  [0:15];   // v3：预测目标（EX 验证用）
  reg  [4:0]  fifo_cnt;      // 0..16

  // ---------------- BPU：req 拍组合查，打拍与 resp 对齐 ----------------
  wire        bq_taken;
  wire [1:0]  bq_offset, bq_cat;
  wire [31:0] bq_target;
  reg         bq_taken_r;
  reg  [1:0]  bq_off_r, bq_cat_r;
  reg  [31:0] bq_tgt_r;
  wire        ras_push, ras_pop;
  wire [31:0] ras_push_addr;

  bpu u_bpu(
    .clk(clk), .rst_n(rst_n),
    .q_pc(req_addr),
    .q_pred_taken(bq_taken), .q_offset(bq_offset),
    .q_target(bq_target), .q_cat(bq_cat),
    .ras_push(ras_push), .ras_push_addr(ras_push_addr), .ras_pop(ras_pop),
    .u_valid(bpu_u_valid), .u_pc(bpu_u_pc), .u_cat(bpu_u_cat),
    .u_taken(bpu_u_taken), .u_target(bpu_u_target)
  );

  // ---------------- req 发射 ----------------
  // 余量预留：当前 cnt + 在途 4 条 ≤ 12（FIFO 16 深，预留一块 4 条）才发新块
  // !resp_kill：pred_fire 转向后在途旧流 req 尚未被消化（杀单挂起）时禁发。
  // 此时 inflight 仍为 1，req_addr=cur_blk+16 会跳过新方向首块，而 take 仍按
  // cur_blk 打 pc 标签 → 数据/标签错位（v2.7 首版 INE@ertn 悬案根因）。
  // 8 深版靠紧余量（cnt+4≤4）意外免疫；加深后必须显式封堵。
  wire [31:0] cur_blk  = {pc_reg[31:4], 4'b0000};
  assign req_addr = cur_blk + (inflight ? 32'd16 : 32'd0);
  assign req_valid = (fifo_cnt + (inflight ? 5'd4 : 5'd0) <= 5'd12)
                   && !redirect && !ic_busy && !resp_kill;

  // ---------------- resp 接收 ----------------
  wire        take      = resp_valid && !resp_kill && !redirect;
  wire [1:0]  pop_num   = rn_pop;
  // v3：预测 taken 且分支在取指窗口内（offset>=skip_cnt）→ 行截断
  wire        pred_fire = take && bq_taken_r && (bq_off_r >= skip_cnt);
  // 首块压入条数 = 4 - skip_cnt；之后块恒 4；pred_fire 截断到 offset+1
  wire [2:0]  push_num  = take
                        ? (pred_fire ? ({1'b0, bq_off_r} + 3'd1 - {1'b0, skip_cnt})
                                     : (3'd4 - {1'b0, skip_cnt}))
                        : 3'd0;
  // RAS 投机操作（截断拍）：call 压返回地址（分支pc+4），ret 弹栈
  assign ras_push      = pred_fire && (bq_cat_r == `BC_CALL);
  assign ras_push_addr = cur_blk + {26'd0, bq_off_r, 2'b00} + 32'd4;
  assign ras_pop       = pred_fire && (bq_cat_r == `BC_RET);

  // ---------------- FIFO 次态（组合） ----------------
  reg [31:0] n_inst [0:15];
  reg [31:0] n_pc   [0:15];
  reg        n_ptk  [0:15];
  reg [31:0] n_ptg  [0:15];
  reg [4:0]  n_cnt;
  integer i;
  always @* begin
    for (i = 0; i < 16; i = i + 1) begin
      n_inst[i] = fifo_inst[i];
      n_pc[i]   = fifo_pc[i];
      n_ptk[i]  = fifo_ptk[i];
      n_ptg[i]  = fifo_ptg[i];
    end
    if (redirect) begin
      n_cnt = 5'd0;
    end else begin
      // 弹出（移位）
      for (i = 0; i < 16; i = i + 1) begin
        if (i + pop_num < 16) begin
          n_inst[i] = fifo_inst[i + pop_num];
          n_pc[i]   = fifo_pc[i + pop_num];
          n_ptk[i]  = fifo_ptk[i + pop_num];
          n_ptg[i]  = fifo_ptg[i + pop_num];
        end
      end
      n_cnt = fifo_cnt - {3'b0, pop_num};
      // 压入整行（追加在弹出后的尾部）：skip 起最多 4 条；pred_fire 截断
      for (i = 0; i < 4; i = i + 1) begin
        if (i < push_num) begin
          n_inst[n_cnt[3:0] + i[3:0]] = resp_line[(skip_cnt + i[1:0])*32 +: 32];
          // 首有效条补回 pc[1:0]（redirect 非对齐目标）；其余条对齐 +4
          n_pc[n_cnt[3:0] + i[3:0]]   = cur_blk + {26'd0, skip_cnt + i[1:0], 2'b00}
                                      + ((i == 0) ? {30'd0, first_low} : 32'd0);
          // v3：被预测 taken 的那条（分支本体）携预测标记与目标
          n_ptk[n_cnt[3:0] + i[3:0]]  = pred_fire && ((skip_cnt + i[1:0]) == bq_off_r);
          n_ptg[n_cnt[3:0] + i[3:0]]  = bq_tgt_r;
        end
      end
      n_cnt = n_cnt + {2'b0, push_num};
    end
  end

  // ---------------- 时序 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_reg    <= BOOT_PC;
      skip_cnt  <= 2'b0;
      first_low <= 2'b0;
      inflight  <= 1'b0;
      resp_kill <= 1'b0;
      fifo_cnt  <= 5'd0;
      bq_taken_r <= 1'b0;
      bq_off_r   <= 2'b0;
      bq_cat_r   <= 2'b0;
      bq_tgt_r   <= 32'b0;
      for (i = 0; i < 16; i = i + 1) begin
        fifo_inst[i] <= 32'b0;
        fifo_pc[i]   <= 32'b0;
        fifo_ptk[i]  <= 1'b0;
        fifo_ptg[i]  <= 32'b0;
      end
    end else begin
      if (redirect) begin
        pc_reg    <= redirect_pc;
        skip_cnt  <= redirect_pc[3:2];
        first_low <= redirect_pc[1:0];
        // 在途 req 作废（resp 到达时丢弃）。杀单必须粘滞到旧 resp 消化：
        // 嵌套 redirect（t5 例外链）时第二次 redirect 的 inflight 已是 0，
        // 直接覆盖会丢掉第一次的杀单 → 旧流 refill 数据混进新 FIFO。
        // 同拍 resp_valid 到达的在途已被本拍消化，无需再杀。
        resp_kill <= (resp_kill || inflight) && !resp_valid;
        inflight  <= 1'b0;
      end else begin
        // inflight 记账：req 发出 +1，resp 收下/丢弃 -1
        case ({req_valid, resp_valid})
          2'b10:   inflight <= 1'b1;
          2'b01:   inflight <= 1'b0;
          default: inflight <= inflight;   // 同拍收发 / 均无：不变
        endcase
        // v3：pred_fire 同拍发出的旧流 req（本拍收 X 发 Y，Y 在旧方向）
        // 必须用 resp_kill 作废；置位优先于"resp 到达清 0"
        if (pred_fire && req_valid)
          resp_kill <= 1'b1;
        else if (resp_valid)
          resp_kill <= 1'b0;               // 作废的 resp 到达，消化完毕
        if (take) begin
          if (pred_fire) begin
            pc_reg    <= bq_tgt_r;         // 预测目标（BTB/RAS 恒 4B 对齐）
            skip_cnt  <= bq_tgt_r[3:2];
            first_low <= 2'b0;
          end else begin
            pc_reg   <= cur_blk + 32'd16;  // 下一块
            skip_cnt <= 2'b0;              // 仅首块有 skip
            first_low <= 2'b0;
          end
        end
      end
      // v3：BPU 查询打拍（req 拍锁存，与 resp 严格对齐；
      //     redirect 后旧查询作废，清 0 防假 pred_fire）
      if (redirect)
        bq_taken_r <= 1'b0;
      else if (req_valid) begin
        bq_taken_r <= bq_taken;
        bq_off_r   <= bq_offset;
        bq_cat_r   <= bq_cat;
        bq_tgt_r   <= bq_target;
      end
      // FIFO
      fifo_cnt <= n_cnt;
      for (i = 0; i < 16; i = i + 1) begin
        fifo_inst[i] <= n_inst[i];
        fifo_pc[i]   <= n_pc[i];
        fifo_ptk[i]  <= n_ptk[i];
        fifo_ptg[i]  <= n_ptg[i];
      end
    end
  end

  // ---------------- 双路组合译码 ----------------
  wire [`DEC_W-1:0] dec0_raw, dec1_raw;

  la32_decoder u_dec0 (
    .inst (fifo_inst[0]),
    .pc   (fifo_pc[0]),
    .dec  (dec0_raw)
  );
  la32_decoder u_dec1 (
    .inst (fifo_inst[1]),
    .pc   (fifo_pc[1]),
    .dec  (dec1_raw)
  );

  // v3：pred 标记/目标注入 dec（随 uop 到 EX，BRU 验证）
  reg [`DEC_W-1:0] dec0_c, dec1_c;
  always @* begin
    dec0_c = dec0_raw;
    dec0_c[`DEC_PRED_TAKEN]  = fifo_ptk[0];
    dec0_c[`DEC_PRED_TARGET] = fifo_ptg[0];
    dec1_c = dec1_raw;
    dec1_c[`DEC_PRED_TAKEN]  = fifo_ptk[1];
    dec1_c[`DEC_PRED_TARGET] = fifo_ptg[1];
  end

  assign dec0 = (fifo_cnt >= 5'd1 && !redirect) ? dec0_c : {`DEC_W{1'b0}};
  assign dec1 = (fifo_cnt >= 5'd2 && !redirect) ? dec1_c : {`DEC_W{1'b0}};

endmodule
