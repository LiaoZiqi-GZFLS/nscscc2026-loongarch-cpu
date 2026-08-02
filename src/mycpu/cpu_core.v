// ============================================================================
// cpu_core.v — LA32R-2S 双发射乱序核流水线顶层（集成）
// 关键胶水逻辑：
//   1) EX 输入选择性前递 MUX（SPEC §2：仅 EX/WB 寄存器 → EX_in，3:1）
//   2) EX/WB 流水线寄存器 + 完成广播（ALU 背靠背零气泡）
//   3) PRF 2 写口仲裁（lane0/lane1 恒赢，mdu/lsu 各 1 深 skid）
//   4) flush 分发：分支误预测（bru）/ 例外（exc）优先级仲裁
//   5) CSR 串行点执行（EX 拍组合读改写，C4 保证 ROB 独占）
// ============================================================================
`include "la32_defs.vh"

module cpu_core(
  input         clk,
  input         rst_n,
  input  [7:0]  intrpt,

  // AXI3 master
  output [3:0]  arid,  output [31:0] araddr, output [3:0] arlen,
  output [2:0]  arsize, output [1:0] arburst, output [1:0] arlock,
  output [3:0]  arcache, output [2:0] arprot,
  output        arvalid, input arready,
  input  [3:0]  rid, input [31:0] rdata, input [1:0] rresp, input rlast,
  input         rvalid, output rready,
  output [3:0]  awid, output [31:0] awaddr, output [3:0] awlen,
  output [2:0]  awsize, output [1:0] awburst, output [1:0] awlock,
  output [3:0]  awcache, output [2:0] awprot,
  output        awvalid, input awready,
  output [3:0]  wid, output [31:0] wdata, output [3:0] wstrb,
  output        wlast, output wvalid, input wready,
  input  [3:0]  bid, input [1:0] bresp, input bvalid, output bready,

  // 提交 trace（chiplab difftest）
  output [31:0] debug0_wb_pc, output [3:0] debug0_wb_rf_wen,
  output [4:0]  debug0_wb_rf_wnum, output [31:0] debug0_wb_rf_wdata,
  output [31:0] debug1_wb_pc, output [3:0] debug1_wb_rf_wen,
  output [4:0]  debug1_wb_rf_wnum, output [31:0] debug1_wb_rf_wdata
);

// ============================ 信号声明 ============================
// flush 汇总
wire        exc_redirect;
wire [31:0] exc_redirect_pc;
wire        bru_flush;            // 分支误预测（EX 组合拍）
wire [31:0] bru_target;
wire [2:0]  bru_ckpt;
wire [4:0]  bru_rob_tag;
wire        redirect       = exc_redirect | bru_flush;
wire [31:0] redirect_pc    = exc_redirect ? exc_redirect_pc : bru_target;
wire        exc_flush      = exc_redirect;   // 例外=全机 flush

// 前端 ↔ ICache ↔ 总线
wire if_arvalid, if_arready, if_rvalid, if_rlast;   // icache ↔ arbiter
wire [31:0] if_araddr, if_rdata;
wire [31:0]  fe_req_addr;                           // frontend ↔ icache
wire         fe_req_valid, fe_resp_valid, fe_ic_busy;
wire [3:0]   if_arlen;
wire [127:0] fe_resp_line;
wire ls_arvalid, ls_arready, ls_rvalid;
wire [31:0] ls_araddr, ls_rdata;
wire ls_awvalid, ls_awready, ls_wvalid, ls_wready, ls_bvalid;
wire [31:0] ls_awaddr, ls_wdata;
wire [3:0]  ls_wstrb;
// DCache 下游（dcache <-> axi_arbiter）
wire dc_arvalid, dc_arready, dc_rvalid, dc_rlast;
wire [31:0] dc_araddr, dc_rdata;
wire [3:0]  dc_arlen;
wire dc_awvalid, dc_awready, dc_wvalid, dc_wready, dc_bvalid;
wire [31:0] dc_awaddr, dc_wdata;
wire [3:0]  dc_wstrb;
wire [3:0]  dc_awlen;
wire        dc_wlast;

// 前端 → 译码
wire [`DEC_W-1:0] dec0, dec1;
wire rn_stall;
wire [1:0] rn_pop;

// rename ↔ 各方
wire [`UOP_W-1:0] rn_uop0, rn_uop1;
wire [1:0]  rn_uop_valid;
wire        rob_full, rob_empty_rob;
wire [4:0]  rob_tail0, rob_tail1, rob_tail_cur;
wire [1:0]  rn_rob_alloc;
wire [5:0]  rn_pdold0, rn_pdold1;
wire        fl_empty0, fl_empty1;
wire [5:0]  fl_pd0, fl_pd1, fl_head;
wire [1:0]  fl_alloc;
wire        ckpt_full;
wire        iq_full, iq_almost;

// IQ ↔ 发射
wire        issue0_valid, issue1_valid;
wire [`UOP_W-1:0] issue0_uop, issue1_uop;

// PRF 读
wire [31:0] prf_rd0a, prf_rd0b, prf_rd1a, prf_rd1b;
wire [63:0] prf_ready;

// EX/WB 寄存器（lane0/lane1）
reg         exwb0_valid, exwb1_valid;
reg  [5:0]  exwb0_pd, exwb1_pd;
reg  [31:0] exwb0_result, exwb1_result;
reg  [4:0]  exwb0_rob, exwb1_rob;
reg         exwb0_wen, exwb1_wen;
reg  [5:0]  exwb0_excpt;
reg  [31:0] exwb0_badv;

// EX 组合结果
wire [31:0] alu0_result, alu1_result;
wire        bru_taken_c;
wire [31:0] bru_target_c;

// MDU / LSU 完成
wire        mdu_done, lsu_done;
wire [31:0] mdu_result, lsu_result;
wire [5:0]  mdu_pd, lsu_pd;
wire [4:0]  mdu_rob, lsu_rob;
wire [5:0]  lsu_excpt;
wire [31:0] lsu_badv;
wire        mdu_busy, lsu_busy, lsu_block_load, lsu_noaccept, lsu_noaccept_ld;
wire [3:0]  lsu_sb_v;
wire [3:0]  lsu_sb_g;
wire [19:0] lsu_sb_tags;

// PRF 写仲裁 + skid
reg         mdu_skid_v, lsu_skid_v;
// v3：skid 占用反压——lsu_done & lsu_skid_v 同拍会丢结果（PRF/ROB 口被 skid 吃掉），
// skid 期间 LSU y 槽驻留、done 晚出（ROB 完成仅延迟无害）。
// 注意还须覆盖"本拍 done 未获口、下拍将入 skid"的情形：否则本拍 y 再放行一笔
// done，下拍它与新生 skid 同拍冲突（dhrystone/fireye_C0 的 FATAL 实证）。
wire        lsu_done_hold = lsu_skid_v |
                            (lsu_done & ~lsu_granted & (lsu_pd != 6'd0));
reg  [5:0]  mdu_skid_pd, lsu_skid_pd;
reg  [31:0] mdu_skid_data, lsu_skid_data;
reg  [4:0]  mdu_skid_rob, lsu_skid_rob;

wire        prf_we0, prf_we1;
wire [5:0]  prf_wa0, prf_wa1;
wire [31:0] prf_wd0, prf_wd1;

// ROB 提交
wire        cmt0_valid, cmt0_wen, cmt0_is_store;
wire [31:0] cmt0_pc, cmt0_wdata;
wire [4:0]  cmt0_rd, cmt0_tag;
wire [5:0]  cmt0_pdnew, cmt0_pdold;
wire        cmt1_valid, cmt1_wen, cmt1_is_store;
wire [31:0] cmt1_pc, cmt1_wdata;
wire [4:0]  cmt1_rd, cmt1_tag;
wire [5:0]  cmt1_pdnew, cmt1_pdold;
wire        rob_exc_active, int_pending;
wire [5:0]  rob_exc_code;
wire [31:0] rob_exc_era, rob_exc_badv;
wire [31:0] csr_eentry, csr_era_out;

// CSR
wire        csr_req;
wire [31:0] csr_rdata;
wire        ll_set, sc_clear, ll_bit;
wire [63:0] stable_cnt;

// ============================ 前端 ============================
frontend u_frontend(
  .clk(clk), .rst_n(rst_n),
  .req_addr(fe_req_addr), .req_valid(fe_req_valid),
  .resp_valid(fe_resp_valid), .resp_line(fe_resp_line), .ic_busy(fe_ic_busy),
  .dec0(dec0), .dec1(dec1),
  .rn_stall(rn_stall), .rn_pop(rn_pop),
  .redirect(redirect), .redirect_pc(redirect_pc),
  // v3 BPU 更新（bru 解析拍：无论预测对错都驱动学习）
  .bpu_u_valid(issue0_valid & (issue0_uop[`UOP_FU] == `FU_BR) & ~exc_redirect),
  .bpu_u_pc(issue0_uop[`UOP_PC]),
  .bpu_u_cat(issue0_uop[`UOP_BR_CAT]),
  .bpu_u_taken(bru_taken_c),
  .bpu_u_target(bru_target_c)
);

// ============================ ICache（8KB 直接映射） ============================
icache u_icache(
  .clk(clk), .rst_n(rst_n),
  .req_addr(fe_req_addr), .req_valid(fe_req_valid), .redirect(redirect),
  .resp_valid(fe_resp_valid), .resp_line(fe_resp_line), .ic_busy(fe_ic_busy),
  .mem_arvalid(if_arvalid), .mem_arready(if_arready), .mem_araddr(if_araddr),
  .mem_arlen(if_arlen),
  .mem_rvalid(if_rvalid), .mem_rdata(if_rdata), .mem_rlast(if_rlast)
);

// ============================ 重命名 ============================
// 分支预测正确（not-taken 命中）：释放 checkpoint 槽
// v3：预测验证——方向一致且（taken 时）目标一致才算正确；
// 正确（含 taken）即 bru_done 释放 checkpoint，不再 flush（核心收益）
wire        bru_pred_tk = issue0_uop[`UOP_PRED_TAKEN];
wire [31:0] bru_pred_tg = issue0_uop[`UOP_PRED_TARGET];
wire        bru_correct = (bru_pred_tk == bru_taken_c) &
                          (~bru_taken_c | (bru_pred_tg == bru_target_c));
wire bru_done      = issue0_valid & (issue0_uop[`UOP_FU] == `FU_BR) & bru_correct & ~exc_redirect;
wire [2:0] bru_done_ckpt = issue0_uop[`UOP_CKPT];
wire [5:0] rob_flush_wen_cnt;
wire       rob_exc_pending;
wire       rn_fl_rollback;
wire [5:0] rn_fl_rollback_head;
wire [4:0] rob_head_tag;
wire       rob_ertn_commit;

rename u_rename(
  .clk(clk), .rst_n(rst_n),
  .dec0(dec0), .dec1(dec1),
  .rn_stall(rn_stall), .rn_pop(rn_pop),
  .uop0(rn_uop0), .uop1(rn_uop1), .uop_valid(rn_uop_valid),
  .rob_full(rob_full), .rob_tail0(rob_tail0), .rob_tail1(rob_tail1),
  .rob_alloc(rn_rob_alloc),
  .pdold0(rn_pdold0), .pdold1(rn_pdold1),
  .fl_empty0(fl_empty0), .fl_empty1(fl_empty1),
  .fl_pd0(fl_pd0), .fl_pd1(fl_pd1), .fl_head(fl_head),
  .fl_alloc(fl_alloc),
  .fl_rollback(rn_fl_rollback), .fl_rollback_head(rn_fl_rollback_head),
  .exc_reclaim_cnt(rob_flush_wen_cnt),
  .iq_almost(iq_almost),
  .cmt0_valid(cmt0_valid), .cmt0_wen(cmt0_wen), .cmt0_rd(cmt0_rd), .cmt0_pdnew(cmt0_pdnew),
  .cmt1_valid(cmt1_valid), .cmt1_wen(cmt1_wen), .cmt1_rd(cmt1_rd), .cmt1_pdnew(cmt1_pdnew),
  .bru_flush(bru_flush), .bru_ckpt(bru_ckpt), .bru_rob(bru_rob_tag),
  .rob_tail_cur(rob_tail_cur),
  .bru_done(bru_done), .bru_done_ckpt(bru_done_ckpt),
  .ckpt_full(ckpt_full),
  .exc_flush(exc_flush),
  .rob_exc_pending(rob_exc_pending), .rob_empty(rob_empty_rob),
  .prf_ready(prf_ready)
);

// 提交释放 freelist：pdold != 0 才回收（物理 0 号永驻映射 r0）
wire [1:0] fl_free_cnt = {cmt1_valid & cmt1_wen & (cmt1_pdold != 6'd0),
                          cmt0_valid & cmt0_wen & (cmt0_pdold != 6'd0)};
// 回收压缩（t4 根因之三）：lane0 不可回收（如分支 pdold=frat[0]=0）而 lane1
// 可回收时，free=1 会错误地把 free_pd0(=lane0 的 0) 压入 ring —— 0 号物理
// 寄存器泄漏进 freelist，之后被当作空闲号分配（fl_pd1=0），毁灭性后果。
// 修复：free_pd0 选"第一个可回收者"。
wire [5:0] fl_free_pd0 = fl_free_cnt[0] ? cmt0_pdold : cmt1_pdold;
wire [5:0] fl_free_pd1 = cmt1_pdold;
freelist u_freelist(
  .clk(clk), .rst_n(rst_n),
  .alloc(fl_alloc & {2{~redirect}}), .new_pd0(fl_pd0), .new_pd1(fl_pd1),
  .empty0(fl_empty0), .empty1(fl_empty1),
  .free(fl_free_cnt[1] ? (fl_free_cnt[0] ? 2'd2 : 2'd1) : (fl_free_cnt[0] ? 2'd1 : 2'd0)),
  .free_pd0(fl_free_pd0), .free_pd1(fl_free_pd1),
  .rollback(rn_fl_rollback), .rollback_head(rn_fl_rollback_head),
  .head_ptr(fl_head)
);

// skid fire 标志（提前声明，ROB done 口使用）
wire mdu_skid_fire, lsu_skid_fire;
// flush 门控标志（提前声明：ROB/IQ 分派禁止）
wire [1:0] enq_gated, alloc_gated;

// ============================ ROB ============================
rob u_rob(
  .clk(clk), .rst_n(rst_n),
  .alloc(alloc_gated),
  .alloc_uop0(rn_uop0), .alloc_uop1(rn_uop1),
  .alloc_pdold0(rn_pdold0), .alloc_pdold1(rn_pdold1),
  .tail0(rob_tail0), .tail1(rob_tail1), .full(rob_full), .empty(),
  .wb0_valid(exwb0_valid), .wb0_rob(exwb0_rob), .wb0_wdata(exwb0_result),
  .wb0_excpt(exwb0_excpt), .wb0_badv(exwb0_badv),
  .wb1_valid(exwb1_valid), .wb1_rob(exwb1_rob), .wb1_wdata(exwb1_result),
  .wb1_excpt(6'h0), .wb1_badv(32'h0),
  .wb2_valid(mdu_done | mdu_skid_fire), .wb2_rob(mdu_skid_v ? mdu_skid_rob : mdu_rob),
  .wb2_wdata(mdu_skid_v ? mdu_skid_data : mdu_result), .wb2_excpt(6'h0), .wb2_badv(32'h0),
  .wb3_valid(lsu_done | lsu_skid_fire), .wb3_rob(lsu_skid_v ? lsu_skid_rob : lsu_rob),
  .wb3_wdata(lsu_skid_v ? lsu_skid_data : lsu_result),
  .wb3_excpt(lsu_skid_v ? 6'h0 : lsu_excpt), .wb3_badv(lsu_skid_v ? 32'h0 : lsu_badv),
  .bru_flush(bru_flush), .bru_rob(bru_rob_tag), .tail_cur(rob_tail_cur),
  .head_tag(rob_head_tag), .ertn_commit(rob_ertn_commit),
  .flush_wen_cnt(rob_flush_wen_cnt), .exc_pending(rob_exc_pending),
  .cmt0_valid(cmt0_valid), .cmt0_pc(cmt0_pc), .cmt0_rd(cmt0_rd), .cmt0_wen(cmt0_wen),
  .cmt0_wdata(cmt0_wdata), .cmt0_pdnew(cmt0_pdnew), .cmt0_pdold(cmt0_pdold),
  .cmt0_is_store(cmt0_is_store), .cmt0_tag(cmt0_tag),
  .cmt1_valid(cmt1_valid), .cmt1_pc(cmt1_pc), .cmt1_rd(cmt1_rd), .cmt1_wen(cmt1_wen),
  .cmt1_wdata(cmt1_wdata), .cmt1_pdnew(cmt1_pdnew), .cmt1_pdold(cmt1_pdold),
  .cmt1_is_store(cmt1_is_store), .cmt1_tag(cmt1_tag),
  .exc_active(rob_exc_active), .exc_code(rob_exc_code), .exc_era(rob_exc_era), .exc_badv(rob_exc_badv),
  .exc_redirect(exc_redirect),
  .eentry(csr_eentry), .era_csr(csr_era_out), .redirect_pc(exc_redirect_pc),
  .int_pending(int_pending), .rob_empty(rob_empty_rob)
);

// ============================ PRF ============================
prf u_prf(
  .clk(clk),
  .rst_n(rst_n),
  .ra0(issue0_uop[`UOP_PJ]), .rb0(issue0_uop[`UOP_PK]),
  .ra1(issue1_uop[`UOP_PJ]), .rb1(issue1_uop[`UOP_PK]),
  .rd0a(prf_rd0a), .rd0b(prf_rd0b), .rd1a(prf_rd1a), .rd1b(prf_rd1b),
  .we0(prf_we0), .wa0(prf_wa0), .wd0(prf_wd0),
  .we1(prf_we1), .wa1(prf_wa1), .wd1(prf_wd1),
  .set_rdy0(prf_we0), .rdy_addr0(prf_wa0),
  .set_rdy1(prf_we1), .rdy_addr1(prf_wa1),
  .set_rdy2(1'b0), .rdy_addr2(6'd0),
  .set_rdy3(1'b0), .rdy_addr3(6'd0),
  .clr_rdy0(rn_uop_valid[0] & rn_uop0[`UOP_RD_WEN] & (rn_uop0[`UOP_PD] != 6'd0)),
  .clr_addr0(rn_uop0[`UOP_PD]),
  .clr_rdy1(rn_uop_valid[1] & rn_uop1[`UOP_RD_WEN] & (rn_uop1[`UOP_PD] != 6'd0)),
  .clr_addr1(rn_uop1[`UOP_PD]),
  .ready_vec(prf_ready)
);

// ============================ 发射队列 ============================
// flush 拍禁止新分派进入 IQ/ROB（rename 寄存器输出的是误路径 uop）
assign enq_gated   = rn_uop_valid & {2{~redirect}};
assign alloc_gated = rn_rob_alloc & {2{~redirect}};

// 发射历史（结构冒险门控用）：选择(T) → 发射呈现(T+1) → FU accept(T+1 末)，
// busy 反馈晚两拍；背对背 LSU/MDU 会在 FU 非 IDLE 拍被丢弃（ROB 永不 done
// 死锁）。门控须覆盖"本周正在呈现的 req"（issue 输出是寄存器，无组合环）
// 与"上拍呈现的 req"两个来源
reg  lsu_issued_r, mdu_issued_r;
wire lsu_struct, lsu_struct_ld, mdu_struct;   // assign 在 lsu_req/mdu_req 定义之后

issue_queue u_iq(
  .clk(clk), .rst_n(rst_n),
  .enq(enq_gated), .enq_uop0(rn_uop0), .enq_uop1(rn_uop1),
  .full(iq_full), .almost_full(iq_almost),
  .enq_inflight({1'b0, enq_gated[0]} + {1'b0, enq_gated[1]}),
  .bcast0_valid(issue0_valid & issue0_uop[`UOP_RD_WEN] &
                (issue0_uop[`UOP_FU] == `FU_ALU || issue0_uop[`UOP_FU] == `FU_BR)),
  .bcast0_pd(issue0_uop[`UOP_PD]),
  .bcast1_valid(issue1_valid & issue1_uop[`UOP_RD_WEN]),
  .bcast1_pd(issue1_uop[`UOP_PD]),
  .prf_ready(prf_ready),
  .issue0_valid(issue0_valid), .issue0_uop(issue0_uop),
  .issue1_valid(issue1_valid), .issue1_uop(issue1_uop),
  .mdu_busy(mdu_struct), .lsu_block_load(lsu_block_load),
  .lsu_struct(lsu_struct), .lsu_struct_ld(lsu_struct_ld),
  .sb_v(lsu_sb_v), .sb_tags(lsu_sb_tags), .sb_g(lsu_sb_g),
  .rob_empty(rob_empty_rob), .rob_head_tag(rob_head_tag),
  .bru_flush(bru_flush), .bru_rob(bru_rob_tag), .rob_tail_cur(rob_tail_cur),
  .rob_full(rob_full),
  .exc_flush(exc_flush)
);

// ============================ EX 输入前递 MUX（SPEC §2 核心） ============================
// lane0 srcj
wire [31:0] ex0_srcj = (exwb0_valid & exwb0_wen & (exwb0_pd == issue0_uop[`UOP_PJ]) & (issue0_uop[`UOP_PJ] != 6'd0)) ? exwb0_result :
                       (exwb1_valid & exwb1_wen & (exwb1_pd == issue0_uop[`UOP_PJ]) & (issue0_uop[`UOP_PJ] != 6'd0)) ? exwb1_result :
                       prf_rd0a;
wire [31:0] ex0_srck = issue0_uop[`UOP_USE_IMM] ? issue0_uop[`UOP_IMM] :
                       (exwb0_valid & exwb0_wen & (exwb0_pd == issue0_uop[`UOP_PK]) & (issue0_uop[`UOP_PK] != 6'd0)) ? exwb0_result :
                       (exwb1_valid & exwb1_wen & (exwb1_pd == issue0_uop[`UOP_PK]) & (issue0_uop[`UOP_PK] != 6'd0)) ? exwb1_result :
                       prf_rd0b;
wire [31:0] ex1_srcj = (exwb0_valid & exwb0_wen & (exwb0_pd == issue1_uop[`UOP_PJ]) & (issue1_uop[`UOP_PJ] != 6'd0)) ? exwb0_result :
                       (exwb1_valid & exwb1_wen & (exwb1_pd == issue1_uop[`UOP_PJ]) & (issue1_uop[`UOP_PJ] != 6'd0)) ? exwb1_result :
                       prf_rd1a;
wire [31:0] ex1_srck = issue1_uop[`UOP_USE_IMM] ? issue1_uop[`UOP_IMM] :
                       (exwb0_valid & exwb0_wen & (exwb0_pd == issue1_uop[`UOP_PK]) & (issue1_uop[`UOP_PK] != 6'd0)) ? exwb0_result :
                       (exwb1_valid & exwb1_wen & (exwb1_pd == issue1_uop[`UOP_PK]) & (issue1_uop[`UOP_PK] != 6'd0)) ? exwb1_result :
                       prf_rd1b;

// ============================ 执行单元 ============================
ex_alu u_alu0(
  .uop(issue0_uop), .src_j(ex0_srcj), .src_k(ex0_srck),
  .result(alu0_result), .br_taken(bru_taken_c), .br_target(bru_target_c)
);
ex_alu u_alu1(
  .uop(issue1_uop), .src_j(ex1_srcj), .src_k(ex1_srck),
  .result(alu1_result), .br_taken(), .br_target()
);

wire mdu_req = issue0_valid & (issue0_uop[`UOP_FU] == `FU_MDU) & ~redirect;
ex_mdu u_mdu(
  .clk(clk), .rst_n(rst_n),
  .req(mdu_req), .uop(issue0_uop), .src_j(ex0_srcj), .src_k(ex0_srck),
  .busy(mdu_busy),
  .done(mdu_done), .result(mdu_result), .done_pd(mdu_pd), .done_rob(mdu_rob),
  .exc_flush(exc_flush), .bru_flush(bru_flush),
  .bru_rob(bru_rob_tag), .rob_tail_cur(rob_tail_cur)
);

wire lsu_req = issue0_valid & (issue0_uop[`UOP_FU] == `FU_LSU) & ~redirect;
// Bug#6 修复：skid 挂起期间禁止再发 LSU/MDU 操作。
// 根因：1 深 skid 缓冲，若 lsu_done/mdu_done 与 skid_v 同拍（前次完成落选
// 未排空、本次完成又到达），旧 skid 项被覆写或新结果被丢弃，丢失的写回
// 永不置 prf_rdy（该指令 ROB 已 done 可正常提交）→ 消费者永久等待 → 全核死锁。
// CDC/DDR 拉长访存延迟后完成时刻随机化，必然撞上该窗口（板上 perf 全灭）。
// 门控后：skid_v=1 时 FU 内必无在途操作（见 lsu.v：S_DN 拍 FSM 忙 noaccept=1，
// skid_v 生效拍 FSM 才回 IDLE，二者无交集），lsu_done/mdu_done 与 skid_v 永不
// 同拍，1 深 skid 即完备。skid 排空无需新增气泡保证：in-order dispatch 下
// 被阻塞的消费者会截断后续派遣，exwb 写口必出现空拍。
// Bug#10：lsu_done/mdu_done 当拍必须入结构门控——done 拍 skid_v 尚未置位、
// FSM 已回 IDLE（noaccept=0），若同拍放行新 LSU/MDU 发射，其完成将与一拍后
// 才出现的 pending skid 碰撞（load：skid 占位致结果捕获被吞 → ROB 永不 done
// 死锁；fireye_B2/C0 实证 FATAL: lsu skid collision，done rob=31 与 skid
// rob=28 相撞）。
assign lsu_struct    = lsu_noaccept    | lsu_issued_r | lsu_req | lsu_skid_v | lsu_done;
// load 专用：不被 sb 满阻塞（noaccept_ld 只含 FSM 忙；sb 满只挡 store）
assign lsu_struct_ld = lsu_noaccept_ld | lsu_issued_r | lsu_req | lsu_skid_v | lsu_done;
assign mdu_struct = mdu_busy | mdu_issued_r | mdu_req | mdu_skid_v | mdu_done;
// 发射历史寄存器（redirect 拍已用 ~redirect 门控 req，直接锁存即可）
always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    lsu_issued_r <= 1'b0;
    mdu_issued_r <= 1'b0;
  end else begin
    lsu_issued_r <= lsu_req;
    mdu_issued_r <= mdu_req;
  end
end
lsu u_lsu(
  .clk(clk), .rst_n(rst_n),
  .req(lsu_req), .uop(issue0_uop), .src_j(ex0_srcj), .src_k(ex0_srck),
  .busy(lsu_busy), .noaccept(lsu_noaccept), .noaccept_ld(lsu_noaccept_ld),
  .sb_v_o(lsu_sb_v), .sb_rob_o(lsu_sb_tags), .sb_g_o(lsu_sb_g),
  .ls_arvalid(ls_arvalid), .ls_arready(ls_arready), .ls_araddr(ls_araddr),
  .ls_rvalid(ls_rvalid), .ls_rdata(ls_rdata),
  .ls_awvalid(ls_awvalid), .ls_awready(ls_awready), .ls_awaddr(ls_awaddr),
  .ls_wvalid(ls_wvalid), .ls_wready(ls_wready), .ls_wdata(ls_wdata), .ls_wstrb(ls_wstrb),
  .ls_bvalid(ls_bvalid),
  // 必须带 valid 门控（n54 实证）：裸接 is_store 时，do_exc/flush 拍头部
  // 槽位的残留 e_store=1 会误授权同 tag 的投机 store（ALE 后的 75430
  // st.w 被 e_store[26]=1 误授权 → 污染 [0x1d0000] → handler stage 读错）
  .sb_commit0(cmt0_valid && cmt0_is_store), .sb_commit_rob0(cmt0_tag),
  .sb_commit1(cmt1_valid && cmt1_is_store), .sb_commit_rob1(cmt1_tag),
  .block_load(lsu_block_load),
  .ll_set(ll_set), .sc_clear(sc_clear), .ll_bit(ll_bit),
  .done(lsu_done), .result(lsu_result), .done_pd(lsu_pd), .done_rob(lsu_rob),
  .done_excpt(lsu_excpt), .done_badv(lsu_badv),
  .done_hold(lsu_done_hold),
  .exc_flush(exc_flush), .bru_flush(bru_flush),
  .bru_rob(bru_rob_tag), .rob_tail_cur(rob_tail_cur)
);

// ============================ CSR 串行点执行 ============================
// C4 保证：CSR uop 发射时 ROB 中仅此一条，EX 拍组合读改写安全
assign csr_req = issue0_valid & (issue0_uop[`UOP_FU] == `FU_CSR) & ~redirect;
wire [31:0] csr_result = csr_rdata;
csr_file u_csr(
  .clk(clk), .rst_n(rst_n),
  .csr_req(csr_req),
  .csr_aluop(issue0_uop[`UOP_ALUOP]),
  .csr_addr(issue0_uop[45:32]),           // IMM 低 14 位 = csr 地址（UOP_IMM 起始于 bit32）
  .csr_wdata(ex0_srcj),                     // csrwr/csrxchg 数据源（rj 字段映射见 decoder 假设4）
  .csr_wmask(ex0_srck),                     // csrxchg 的 mask（rk 字段）
  .csr_rdata(csr_rdata),
  .exc_active(rob_exc_active), .exc_code(rob_exc_code),
  .exc_era(rob_exc_era), .exc_badv(rob_exc_badv),
  .eentry(csr_eentry),
  .ertn_exec(rob_ertn_commit), .era_out(csr_era_out),
  .intrpt(intrpt), .int_pending(int_pending),
  .ll_set(ll_set), .sc_clear(sc_clear),
  .bru_flush(bru_flush), .exc_flush_ll(exc_flush),
  .ll_bit(ll_bit),
  .stable_cnt(stable_cnt)
);
// ertn 提交检测：ROB 提交一条 FU_CSR/AOP_ERTN——由 ROB 内部识别并输出 ertn_exec_w
// （集成阶段与 coder B 核对该信号来源）

// ============================ EX/WB 寄存器 ============================
always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    exwb0_valid <= 1'b0; exwb1_valid <= 1'b0;
  end else begin
    // lane0：ALU/BR 单拍；CSR 组合读；MDU/LSU 走各自完成口
    // bru_flush 拍保留分支自身写回（误预测只杀更年轻者，分支必须标 done
    // 否则其 ROB 项永不完成死锁）；exc_redirect 为全机 flush 仍清零
    exwb0_valid <= issue0_valid & (~redirect | bru_flush) &
                   (issue0_uop[`UOP_FU] == `FU_ALU ||
                    issue0_uop[`UOP_FU] == `FU_BR  ||
                    issue0_uop[`UOP_FU] == `FU_CSR);
    exwb0_pd    <= issue0_uop[`UOP_PD];
    exwb0_wen   <= issue0_uop[`UOP_RD_WEN];
    exwb0_rob   <= issue0_uop[`UOP_ROB];
    exwb0_result<= (issue0_uop[`UOP_FU] == `FU_CSR) ? csr_result : alu0_result;
    exwb0_excpt <= (issue0_uop[`UOP_EXCPT] != `EXC_NONE) ? issue0_uop[`UOP_EXCPT] :
                   (issue0_uop[`UOP_ALUOP] == `AOP_SYSCALL) ? `EXC_SYS :
                   (issue0_uop[`UOP_ALUOP] == `AOP_BREAK)   ? `EXC_BRK : `EXC_NONE;
    exwb0_badv  <= issue0_uop[`UOP_PC];

    exwb1_valid <= issue1_valid & ~redirect;
    exwb1_pd    <= issue1_uop[`UOP_PD];
    exwb1_wen   <= issue1_uop[`UOP_RD_WEN];
    exwb1_rob   <= issue1_uop[`UOP_ROB];
    exwb1_result<= alu1_result;
  end
end

// 分支误预测判定（v1 全预测 not-taken：凡 taken 即误预测）
// v3：仅预测错误才 flush；目标 = 实际 taken 目标，否则顺序 pc+4
assign bru_flush   = issue0_valid & (issue0_uop[`UOP_FU] == `FU_BR) & ~bru_correct & ~exc_redirect;
assign bru_target  = bru_taken_c ? bru_target_c : (issue0_uop[`UOP_PC] + 32'd4);
assign bru_ckpt    = issue0_uop[`UOP_CKPT];
assign bru_rob_tag = issue0_uop[`UOP_ROB];

// ============================ PRF 写仲裁 + skid ============================
// 规则：lane0/lane1 恒赢；mdu/lsu 落选进 1 深 skid（其完成间隔 >>2 拍，安全）
wire mdu_fire = mdu_done | mdu_skid_v;
wire lsu_fire = lsu_done | lsu_skid_v;
assign mdu_skid_fire = mdu_skid_v;   // ROB done 口用
assign lsu_skid_fire = lsu_skid_v;

assign prf_we0 = exwb0_valid & exwb0_wen ? 1'b1 :
                 (mdu_fire & (mdu_skid_v ? mdu_skid_pd : mdu_pd) != 6'd0) ? 1'b1 :
                 (lsu_fire & (lsu_skid_v ? lsu_skid_pd : lsu_pd) != 6'd0) ? 1'b1 : 1'b0;
assign prf_wa0 = exwb0_valid & exwb0_wen ? exwb0_pd :
                 mdu_fire ? (mdu_skid_v ? mdu_skid_pd : mdu_pd) : (lsu_skid_v ? lsu_skid_pd : lsu_pd);
assign prf_wd0 = exwb0_valid & exwb0_wen ? exwb0_result :
                 mdu_fire ? (mdu_skid_v ? mdu_skid_data : mdu_result) : (lsu_skid_v ? lsu_skid_data : lsu_result);

wire mdu_took0 = ~(exwb0_valid & exwb0_wen) & mdu_fire;
assign prf_we1 = exwb1_valid & exwb1_wen ? 1'b1 :
                 (~mdu_took0 & mdu_fire & (mdu_skid_v ? mdu_skid_pd : mdu_pd) != 6'd0) ? 1'b1 :
                 (lsu_fire & (lsu_skid_v ? lsu_skid_pd : lsu_pd) != 6'd0) ? 1'b1 : 1'b0;
assign prf_wa1 = exwb1_valid & exwb1_wen ? exwb1_pd :
                 (~mdu_took0 & mdu_fire) ? (mdu_skid_v ? mdu_skid_pd : mdu_pd) : (lsu_skid_v ? lsu_skid_pd : lsu_pd);
assign prf_wd1 = exwb1_valid & exwb1_wen ? exwb1_result :
                 (~mdu_took0 & mdu_fire) ? (mdu_skid_v ? mdu_skid_data : mdu_result) : (lsu_skid_v ? lsu_skid_data : lsu_result);

wire mdu_granted = mdu_fire & (prf_we0 & prf_wa0 == (mdu_skid_v ? mdu_skid_pd : mdu_pd) |
                               prf_we1 & prf_wa1 == (mdu_skid_v ? mdu_skid_pd : mdu_pd));
wire lsu_granted = lsu_fire & (prf_we0 & prf_wa0 == (lsu_skid_v ? lsu_skid_pd : lsu_pd) |
                               prf_we1 & prf_wa1 == (lsu_skid_v ? lsu_skid_pd : lsu_pd));

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    mdu_skid_v <= 1'b0; lsu_skid_v <= 1'b0;
  end else begin
    // ~mdu_skid_v / ~lsu_skid_v：门控修复后不可达的防覆写保护（双保险）
    if (mdu_done & ~mdu_granted & (mdu_pd != 6'd0) & ~mdu_skid_v) begin
      mdu_skid_v <= 1'b1; mdu_skid_pd <= mdu_pd;
      mdu_skid_data <= mdu_result; mdu_skid_rob <= mdu_rob;
    end else if (mdu_skid_v & mdu_granted) mdu_skid_v <= 1'b0;
    if (lsu_done & ~lsu_granted & (lsu_pd != 6'd0) & ~lsu_skid_v) begin
      lsu_skid_v <= 1'b1; lsu_skid_pd <= lsu_pd;
      lsu_skid_data <= lsu_result; lsu_skid_rob <= lsu_rob;
    end else if (lsu_skid_v & lsu_granted) lsu_skid_v <= 1'b0;
`ifdef VERILATOR
    // 仿真哨兵：门控修复若被绕过（done 与 skid_v 同拍）立刻暴露
    if (lsu_done & lsu_skid_v) begin
      $display("FATAL: lsu skid collision @%0t", $time); $fatal;
    end
    if (mdu_done & mdu_skid_v) begin
      $display("FATAL: mdu skid collision @%0t", $time); $fatal;
    end
`endif
  end
end

// ============================ DCache（lsu <-> arbiter shim） ============================
dcache u_dcache(
  .clk(clk), .rst_n(rst_n),
  .s_arvalid(ls_arvalid), .s_arready(ls_arready), .s_araddr(ls_araddr),
  .s_rvalid(ls_rvalid), .s_rdata(ls_rdata),
  .s_awvalid(ls_awvalid), .s_awready(ls_awready), .s_awaddr(ls_awaddr),
  .s_wvalid(ls_wvalid), .s_wready(ls_wready), .s_wdata(ls_wdata), .s_wstrb(ls_wstrb),
  .s_bvalid(dc_bvalid),
  .m_arvalid(dc_arvalid), .m_arready(dc_arready), .m_araddr(dc_araddr), .m_arlen(dc_arlen),
  .m_rvalid(dc_rvalid), .m_rdata(dc_rdata), .m_rlast(dc_rlast),
  .m_awvalid(dc_awvalid), .m_awready(dc_awready), .m_awaddr(dc_awaddr), .m_awlen(dc_awlen),
  .m_wvalid(dc_wvalid), .m_wready(dc_wready), .m_wdata(dc_wdata), .m_wstrb(dc_wstrb),
  .m_wlast(dc_wlast),
  .m_bvalid(ls_bvalid)
);

// ============================ AXI 仲裁 ============================
axi_arbiter u_axi(
  .clk(clk), .rst_n(rst_n),
  .if_arvalid(if_arvalid), .if_arready(if_arready), .if_araddr(if_araddr),
  .if_rvalid(if_rvalid), .if_rdata(if_rdata), .if_rlast(if_rlast),
  .ls_arvalid(dc_arvalid), .ls_arready(dc_arready), .ls_araddr(dc_araddr),
  .ls_arlen(dc_arlen), .if_arlen(if_arlen),
  .ls_rvalid(dc_rvalid), .ls_rdata(dc_rdata), .ls_rlast(dc_rlast),
  .ls_awvalid(dc_awvalid), .ls_awready(dc_awready), .ls_awaddr(dc_awaddr), .ls_awlen(dc_awlen),
  .ls_wvalid(dc_wvalid), .ls_wready(dc_wready), .ls_wdata(dc_wdata), .ls_wstrb(dc_wstrb),
  .ls_wlast(dc_wlast),
  .ls_bvalid(dc_bvalid),
  .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
  .arlock(arlock), .arcache(arcache), .arprot(arprot), .arvalid(arvalid), .arready(arready),
  .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
  .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
  .awlock(awlock), .awcache(awcache), .awprot(awprot), .awvalid(awvalid), .awready(awready),
  .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
  .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready)
);

// ============================ 提交 trace ============================
assign debug0_wb_pc      = cmt0_valid ? cmt0_pc    : 32'h0;
assign debug0_wb_rf_wen  = cmt0_valid & cmt0_wen ? 4'hf : 4'h0;
assign debug0_wb_rf_wnum = cmt0_rd;
assign debug0_wb_rf_wdata= cmt0_wdata;
assign debug1_wb_pc      = cmt1_valid ? cmt1_pc    : 32'h0;
assign debug1_wb_rf_wen  = cmt1_valid & cmt1_wen ? 4'hf : 4'h0;
assign debug1_wb_rf_wnum = cmt1_rd;
assign debug1_wb_rf_wdata= cmt1_wdata;

endmodule
