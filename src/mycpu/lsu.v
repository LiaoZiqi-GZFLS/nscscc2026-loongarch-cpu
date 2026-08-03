// ============================================================================
// lsu.v — LA32R-2S 访存单元（lane0 专属）+ 4 深 store buffer（x/y 双槽流水）
// 见 LSU_V3_SPEC.md（单一事实源）。纯 Verilog-2001。
// Pipeline structure refers to NOP-Core (MIT License). Copyright (c) 2023 NOP-Group.
// （仅借鉴"流水段+halt"结构思想，全部代码自写）
//
// 流水结构（两槽，严格按序推进）：
//   accept(T) → x 槽(T+1：地址/ALE/kill/分类已寄存) → y 槽(T+2 起：访存/完成)
//   - load：y 内 Y_AR（发 AR 等握手）→ Y_R（等 rvalid）→ 当拍出 done；
//     done_hold 则锁存结果转 Y_DN 等放行。稳态 1 load/2 拍（打满 dcache pend 上限）
//   - store/sc/ALE：y 内 Y_DN 单拍——push sb / done 同拍（done_hold 驻留等放行）
//   - done_hold（cpu_core 反压=lsu_skid_v）：skid 占用时 done 晚出，ROB 完成
//     仅延迟，无害；skid 占用期 y 绝不发 done（lsu_done & lsu_skid_v 会丢结果）
//
// v5（LSU_V5_SPEC.md）：store→load 字节前递 + C6 放宽：
//   - load 的存储序不再靠 IQ C6 sb 阻塞（已删），改由本单元前递保证：
//     y 槽 load 等待期间每拍寄存化 y_fwd/y_fwd_mask（源=sb∪x/y 幻影全表
//     字节 CAM，年龄谓词=C6 环形公式复用 rob_head_tag/rob_tail_cur/rob_full；
//     多源 mux 链寄存化，rvalid→result 仅余一级 AND-OR 字节选择）
//   - uncached/LL 不前递，且走 Y_AR 驻留门：无更老 store 才发 AR（MMIO 副作用序）
//   - load AR 与 sb drain（W 事务）在 LSU 内互斥：drain 在途/将发不发 AR，
//     AR 挂起/将发不进 drain（dcache readys 仲裁顶不住同拍双握手，func43/44 类）
//
// 要点（语义逐项保留自串行 FSM 版）：
//  - 地址 = src_j + UOP_IMM；对齐检查，违例 -> done_excpt=EXC_ALE, 不发 AXI
//  - load: AR->R，按 AOP 做字节/半字提取与符号/零扩展；LL 同 LDW 并 ll_set 一拍
//  - store: 算好 {addr,data,wstrb,rob_tag} 入 store buffer，
//    等 sb_commit 授权（rob_tag 匹配）后按 buffer 顺序发 AW/W，B 后弹出
//  - SC: 检查 ll_bit，成功走 store 流程且 result=1；失败不写内存 result=0；
//    两种情况均 sc_clear 一拍（done 拍）
//  - block_load = store buffer 非空 || x/y 槽内有将入 sb 的 store（C6 保守）
//  - bru_flush: 丢弃 ROB tag 落在 (bru_rob, rob_tail_cur) 开区间的未授权项
//    exc_flush: 丢弃全部未授权项（已授权项不受 flush 影响）
//  - flush 杀伤逐段镜像：accept 拍 a_kill 不收 / x 杀清空 / y 杀
//    （Y_AR 未握手撤 AR；Y_R 标记 killed 收数据丢弃；Y_DN 无 done 无 push）
//  - AXI 单 outstanding（y 单槽天然保证至多 1 个 AR 在途，I10）
//  - busy = x/y 占用 | AXI 写在途 | 有已授权待发项 | store buffer 满
// ============================================================================
`include "la32_defs.vh"

module lsu(
  input clk, input rst_n,
  input req,
  /* verilator lint_off UNUSEDSIGNAL */  // 仅使用 IMM/ALUOP/ROB/PD 字段，其余上游戏用
  input [`UOP_W-1:0] uop,
  /* verilator lint_on UNUSEDSIGNAL */
  input [31:0] src_j,          // base 寄存器值
  input [31:0] src_k,          // store 数据
  output busy,
  // AXI 客户端（到 axi_arbiter，读优先）
  output reg ls_arvalid, input ls_arready, output reg [31:0] ls_araddr,
  input ls_rvalid, input [31:0] ls_rdata,
  output reg ls_awvalid, input ls_awready, output reg [31:0] ls_awaddr,
  output reg ls_wvalid, input ls_wready, output reg [31:0] ls_wdata, output reg [3:0] ls_wstrb,
  input ls_bvalid,
  // store buffer 提交授权（ROB 提交时一拍脉冲）
  // 双提交授权：cmt0/cmt1 可能同拍都是 store，两路独立匹配，
  // 单路授权会漏掉另一项 → 永不授权 → buffer 满死锁（func_test n13 实证）
  input sb_commit0, input [4:0] sb_commit_rob0,
  input sb_commit1, input [4:0] sb_commit_rob1,
  output block_load,                       // C6：store buffer 有未完成项
  output noaccept,                         // 结构冒险(store)：槽满/将满，下拍不能 accept
  output noaccept_ld,                      // 结构冒险(load)：仅槽占用（不含 sb 状态，I2）
  output [`SB_DEPTH-1:0]  sb_v_o,          // store buffer 有效位（C6 精确化）
  output [`SB_DEPTH*5-1:0] sb_rob_o,       // store buffer 各项 ROB 标签
  output [`SB_DEPTH-1:0]  sb_g_o,          // store buffer 各项已提交授权（C6 补洞：已提交 store 必阻塞一切 load）
  // LLbit 交互（csr_file）
  output reg ll_set, output reg sc_clear, input ll_bit,
  // 完成输出
  output reg done, output reg [31:0] result,
  output reg [5:0] done_pd, output reg [4:0] done_rob,
  output reg [5:0] done_excpt, output reg [31:0] done_badv,
  input done_hold,                         // v3：skid 占用反压（y 驻留，done 晚出）
  input exc_flush, input bru_flush, input [4:0] bru_rob, input [4:0] rob_tail_cur,
  input [4:0] rob_head_tag,                // v5：C6 环形年龄谓词（前递/驻留门）
  input rob_full                           // v5：ROB 满（窗口=32 项）
);

  // ---------------- y 微态（原 FSM 收缩） ----------------
  localparam Y_AR = 2'd0;   // load：持 arvalid 等握手
  localparam Y_R  = 2'd1;   // load：等 rvalid（killed 则收数据丢弃）
  localparam Y_DN = 2'd2;   // store/sc/ALE 或 done_hold 驻留 load：出 done

  // ---------------- x 槽（前槽） ----------------
  reg        x_valid;
  reg [5:0]  x_aop;
  reg [31:0] x_addr;
  reg [31:0] x_sk;
  reg [5:0]  x_pd;
  reg        x_rdwen;
  reg [4:0]  x_rob;
  reg        x_sc;
  reg        x_push;     // 完成后需入 store buffer（store / SC 成功；ALE 除外）
  reg        x_ale;
  reg        x_ld;
  reg        x_uc;       // v5：uncached（MMIO）访存，不前递 + Y_AR 驻留门
  reg [31:0] x_res;      // SC 结果预计算（accept 拍按 ll_bit 定）

  // ---------------- y 槽（后槽） ----------------
  reg        y_valid;
  reg [1:0]  y_state;
  reg [5:0]  y_aop;
  reg [31:0] y_addr;
  reg [31:0] y_sk;
  reg [5:0]  y_pd;
  reg        y_rdwen;
  reg [4:0]  y_rob;
  reg        y_sc;
  reg        y_push;
  reg        y_ale;
  reg        y_uc;
  reg [31:0] y_res;
  reg        y_killed;   // 在途 load 被 flush 杀死（等 R 丢弃）
  reg [31:0] y_fwd;      // v5：寄存化前递字（多源 mux 链在寄存器前完成）
  reg [3:0]  y_fwd_mask; // v5：前递覆盖字节掩码

  // ---------------- store buffer（4 深，环形） ----------------
  reg [31:0] sb_addr [0:`SB_DEPTH-1];
  reg [31:0] sb_data [0:`SB_DEPTH-1];
  reg [3:0]  sb_strb [0:`SB_DEPTH-1];
  reg [4:0]  sb_rob  [0:`SB_DEPTH-1];
  reg [`SB_DEPTH-1:0] sb_valid;
  reg [`SB_DEPTH-1:0] sb_granted;
  reg [1:0]  sb_hp;       // 头指针（最老）
  reg [2:0]  sb_cnt;      // 有效项数 0..4

  // AXI 写通道状态
  reg wr_act;             // 有一笔在途写（AW/W 进行中或等 B）

  // ---------------- ROB 环形区间判断：tag ∈ (from, tail) 开区间 ----------------
  // Bug#9：ROB 满（count=32, tail==head）时旧式 (d2!=0)&&(d1!=0)&&(d1<d2)
  // 对所有项返回假 → 满 ROB 上的分支 flush 杀不到任何投机项（sb 残留投机
  // store → granted 项卡 hp 后 → C6 全堵 load → 全局死锁，dhrystone 实证）。
  // 通用 -1 形式：tag ∈ (from, tail) 开区间 <=> (tag-from-1) < (tail-from-1)
  // （mod 32），满 ROB（区间=31 项）亦正确；非满情形与旧式逐值等价已验证。
  function in_range;
    input [4:0] tag;
    input [4:0] from;
    input [4:0] tail;
    begin
      in_range = ((tag - from - 5'd1) < (tail - from - 5'd1));
    end
  endfunction

  // v5：C6 同款环形年龄谓词——src 是否比 dst(load) 老
  // （pos = tag-head 距头环形位置；老 = 位置更靠前：
  //   src 老于 dst <=> pos_src < pos_dst 且 src 在 ROB 占用窗内。
  //   与 IQ C6 同源：C6 放行例外"sb 年轻"= (pos_ld < pos_sb < cnt)，取反即老）
  function age_older;
    input [4:0] src;
    input [4:0] dst;
    input [4:0] head;
    input [4:0] tail;
    input       full;
    begin
      age_older = ((src - head) < (dst - head))
               && ({1'b0, (src - head)} < (full ? 6'd32 : {1'b0, (tail - head)}));
    end
  endfunction

  // ---------------- load 数据提取 ----------------
  function [31:0] ld_extract;
    input [5:0]  aop;
    input [31:0] data;
    input [1:0]  a;
    reg [7:0]  b;
    reg [15:0] h;
    begin
      case (a)
        2'b00:   b = data[7:0];
        2'b01:   b = data[15:8];
        2'b10:   b = data[23:16];
        default: b = data[31:24];
      endcase
      h = a[1] ? data[31:16] : data[15:0];
      case (aop)
        `AOP_LDB:  ld_extract = {{24{b[7]}}, b};
        `AOP_LDBU: ld_extract = {24'b0, b};
        `AOP_LDH:  ld_extract = {{16{h[15]}}, h};
        `AOP_LDHU: ld_extract = {16'b0, h};
        default:   ld_extract = data;   // LDW / LL
      endcase
    end
  endfunction

  // ---------------- store 字节使能 / 数据摆放 ----------------
  function [3:0] st_strb;
    input [5:0] aop;
    input [1:0] a;
    begin
      case (aop)
        `AOP_STB:  st_strb = (4'b0001 << a);
        `AOP_STH:  st_strb = a[1] ? 4'b1100 : 4'b0011;
        default:   st_strb = 4'b1111;     // STW / SC
      endcase
    end
  endfunction

  function [31:0] st_data;
    input [5:0]  aop;
    input [31:0] k;
    begin
      case (aop)
        `AOP_STB:  st_data = {4{k[7:0]}};    // 复制到所有 lane，wstrb 选
        `AOP_STH:  st_data = {2{k[15:0]}};
        default:   st_data = k;
      endcase
    end
  endfunction

  // ---------------- 接收拍组合译码（原样保留） ----------------
  wire [5:0]  a_aop   = uop[`UOP_ALUOP];
  wire [31:0] a_addr  = src_j + uop[`UOP_IMM];
  wire a_isld = ((a_aop >= `AOP_LDB) && (a_aop <= `AOP_LDHU)) || (a_aop == `AOP_LL);
  wire a_isst = (a_aop >= `AOP_STB) && (a_aop <= `AOP_STW);
  wire a_issc = (a_aop == `AOP_SC);
  wire a_ale  = (((a_aop == `AOP_LDH) || (a_aop == `AOP_LDHU) || (a_aop == `AOP_STH)) && a_addr[0])
             || (((a_aop == `AOP_LDW) || (a_aop == `AOP_LL) || (a_aop == `AOP_STW) || (a_aop == `AOP_SC))
                 && (|a_addr[1:0]));
  // 本拍新来的请求若已被 flush 覆盖（与分支同拍执行的年幼指令），直接不接收
  wire a_kill = exc_flush || (bru_flush && in_range(uop[`UOP_ROB], bru_rob, rob_tail_cur));
  // v5：uncached 判定（与 dcache 同源：程序区 0x1c / DDR 0x0 为 cached）
  wire a_uc = !((a_addr[31:24] == 8'h1c) || (a_addr[31:28] == 4'h0));

  // ---------------- 槽位 kill 条件（in_range Bug#9 形式原样保留） ----------------
  wire x_kill = exc_flush || (bru_flush && in_range(x_rob, bru_rob, rob_tail_cur));
  wire y_kill = exc_flush || (bru_flush && in_range(y_rob, bru_rob, rob_tail_cur));

  // ---------------- v5：AR 与 drain（W 事务）互斥（I6'，dcache 仲裁顶不住
  //    同拍双握手，func43/44 类——规格 §4 允许的退路：AR 发出拍无 drain 中 W） ----------------
  wire drain_req   = sb_valid[sb_hp] && sb_granted[sb_hp];   // drain 将发（组合）
  wire ar_gate     = !wr_act && !drain_req;                  // 发 AR 前提：无 drain 在途/将发

  // ---------------- v5：uc/LL Y_AR 驻留门——无更老 store（I13） ----------------
  // sb 全表 + x/y 幻影做年龄过滤（granted 无条件更老）；x/y 幻影对 y 内 load
  // 谓词自动为假（更年轻/自身），结构纳入防未来留洞
  wire [3:0] uc_older_sb;
  genvar g_uc;
  generate
    for (g_uc = 0; g_uc < `SB_DEPTH; g_uc = g_uc + 1) begin : g_uc_older
      assign uc_older_sb[g_uc] = sb_valid[g_uc] &&
             (sb_granted[g_uc] ||
              age_older(sb_rob[g_uc], y_rob, rob_head_tag, rob_tail_cur, rob_full));
    end
  endgenerate
  wire uc_older_any = (|uc_older_sb)
                   || (x_valid && x_push &&
                       age_older(x_rob, y_rob, rob_head_tag, rob_tail_cur, rob_full))
                   || (y_valid && y_push &&
                       age_older(y_rob, y_rob, rob_head_tag, rob_tail_cur, rob_full));

  // ---------------- v5：store→load 字节前递 CAM（全表，年龄过滤） ----------------
  // 源扫描序：sb 从 hp 起 cnt 项（年龄递增）→ y 幻影 → x 幻影（最年轻后盖）。
  // 每字节：最老先盖、最年轻后盖。结果每拍寄存化进 y_fwd/y_fwd_mask，
  // rvalid→result 仅余一级 AND-OR（多源 mux 链全部在寄存器前完成）。
  wire y_is_load = y_valid &&
      (((y_aop >= `AOP_LDB) && (y_aop <= `AOP_LDHU)) || (y_aop == `AOP_LL));
  integer fi;
  reg [31:0] fwd_word_c;
  reg [3:0]  fwd_mask_c;
  reg [1:0]  fidx;
  reg [3:0]  x_strb_c, y_strb_c;
  reg [31:0] x_data_c, y_data_c;
  always @* begin
    fwd_word_c = 32'b0;
    fwd_mask_c = 4'b0;
    x_strb_c = st_strb(x_aop, x_addr[1:0]);
    y_strb_c = st_strb(y_aop, y_addr[1:0]);
    x_data_c = st_data(x_aop, x_sk);
    y_data_c = st_data(y_aop, y_sk);
    for (fi = 0; fi < `SB_DEPTH; fi = fi + 1) begin
      fidx = sb_hp + fi[1:0];
      if ((fi < sb_cnt) && sb_valid[fidx] && (sb_addr[fidx][31:2] == y_addr[31:2]) &&
          (sb_granted[fidx] ||
           age_older(sb_rob[fidx], y_rob, rob_head_tag, rob_tail_cur, rob_full))) begin
        if (sb_strb[fidx][0]) begin fwd_word_c[7:0]   = sb_data[fidx][7:0];   fwd_mask_c[0] = 1'b1; end
        if (sb_strb[fidx][1]) begin fwd_word_c[15:8]  = sb_data[fidx][15:8];  fwd_mask_c[1] = 1'b1; end
        if (sb_strb[fidx][2]) begin fwd_word_c[23:16] = sb_data[fidx][23:16]; fwd_mask_c[2] = 1'b1; end
        if (sb_strb[fidx][3]) begin fwd_word_c[31:24] = sb_data[fidx][31:24]; fwd_mask_c[3] = 1'b1; end
      end
    end
    // y 幻影（谓词对自身自动为假，结构纳入）
    if (y_valid && y_push && (y_addr[31:2] == y_addr[31:2]) &&
        age_older(y_rob, y_rob, rob_head_tag, rob_tail_cur, rob_full)) begin
      if (y_strb_c[0]) begin fwd_word_c[7:0]   = y_data_c[7:0];   fwd_mask_c[0] = 1'b1; end
      if (y_strb_c[1]) begin fwd_word_c[15:8]  = y_data_c[15:8];  fwd_mask_c[1] = 1'b1; end
      if (y_strb_c[2]) begin fwd_word_c[23:16] = y_data_c[23:16]; fwd_mask_c[2] = 1'b1; end
      if (y_strb_c[3]) begin fwd_word_c[31:24] = y_data_c[31:24]; fwd_mask_c[3] = 1'b1; end
    end
    // x 幻影（最年轻，最后盖；对 y 内 load 谓词自动为假，结构纳入）
    if (x_valid && x_push && (x_addr[31:2] == y_addr[31:2]) &&
        age_older(x_rob, y_rob, rob_head_tag, rob_tail_cur, rob_full)) begin
      if (x_strb_c[0]) begin fwd_word_c[7:0]   = x_data_c[7:0];   fwd_mask_c[0] = 1'b1; end
      if (x_strb_c[1]) begin fwd_word_c[15:8]  = x_data_c[15:8];  fwd_mask_c[1] = 1'b1; end
      if (x_strb_c[2]) begin fwd_word_c[23:16] = x_data_c[23:16]; fwd_mask_c[2] = 1'b1; end
      if (x_strb_c[3]) begin fwd_word_c[31:24] = x_data_c[31:24]; fwd_mask_c[3] = 1'b1; end
    end
  end

  // ---------------- 推进/驻留公式（规格 §2 严格） ----------------
  wire ar_hs = ls_arvalid && ls_arready;
  // I1（sb 不溢出）：store/sc 的 x→y 须保证其 push 拍 sb 必有槽（保守公式）
  wire y_store_pend = y_valid && y_push;                  // y 内有未 push store
  wire store_gate = !(&sb_valid)
                 && !((sb_cnt >= (`SB_DEPTH-1)) && y_store_pend);
  // y_leaving：本拍末 y 空出（被杀 load 收完 R 直接空出无 done；done_hold 驻留）
  wire y_leaving = y_valid && (
         (y_state == Y_AR && y_kill && !ar_hs)                       // 未握手撤 AR
      || (y_state == Y_R  && ls_rvalid && (y_killed || y_kill || !done_hold))
      || (y_state == Y_DN && (y_kill || !done_hold)));
  // x→y 推进：x 有效未杀 && y 将空 && store/sc 过 I1 门控
  wire x_adv = x_valid && !x_kill && (!y_valid || y_leaving)
            && (!x_push || store_gate);
  // accept：x 空或将推进
  wire accept = req && (!x_valid || x_adv) && !a_kill;

  // store 入 buffer 脉冲（Y_DN 完成拍且未被杀；done_hold 时随 done 一起推迟）
  wire push = y_valid && (y_state == Y_DN) && !done_hold && !y_kill && y_push;

  // v5：load 数据选择——cacheable 用"dcache 字 ⊕ 寄存化前递字节"，
  // uncached/LL 维持 ls_rdata（不前递）；一级 AND-OR，mux 链已寄存化
  wire [31:0] y_fwd_mask32 = {{8{y_fwd_mask[3]}}, {8{y_fwd_mask[2]}},
                              {8{y_fwd_mask[1]}}, {8{y_fwd_mask[0]}}};
  // I13'（v5.1）：UC/LL 同样吃前递合并（驻留门拆除后的存储序保障）
  wire [31:0] y_ld_data = ((ls_rdata & ~y_fwd_mask32) | (y_fwd & y_fwd_mask32));

  // ---------------- x/y 流水 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      x_valid   <= 1'b0;
      x_aop     <= 6'b0;
      x_addr    <= 32'b0;
      x_sk      <= 32'b0;
      x_pd      <= 6'b0;
      x_rdwen   <= 1'b0;
      x_rob     <= 5'b0;
      x_sc      <= 1'b0;
      x_push    <= 1'b0;
      x_ale     <= 1'b0;
      x_ld      <= 1'b0;
      x_uc      <= 1'b0;
      x_res     <= 32'b0;
      y_valid   <= 1'b0;
      y_state   <= Y_AR;
      y_aop     <= 6'b0;
      y_addr    <= 32'b0;
      y_sk      <= 32'b0;
      y_pd      <= 6'b0;
      y_rdwen   <= 1'b0;
      y_rob     <= 5'b0;
      y_sc      <= 1'b0;
      y_push    <= 1'b0;
      y_ale     <= 1'b0;
      y_uc      <= 1'b0;
      y_res     <= 32'b0;
      y_killed  <= 1'b0;
      y_fwd     <= 32'b0;
      y_fwd_mask <= 4'b0;
      ls_arvalid <= 1'b0;
      ls_araddr  <= 32'b0;
      done      <= 1'b0;
      result    <= 32'b0;
      done_pd   <= 6'b0;
      done_rob  <= 5'b0;
      done_excpt <= `EXC_NONE;
      done_badv <= 32'b0;
      ll_set    <= 1'b0;
      sc_clear  <= 1'b0;
    end else begin
      // 一拍脉冲默认清零
      done     <= 1'b0;
      ll_set   <= 1'b0;
      sc_clear <= 1'b0;

      // ---- x 槽：杀 > 收 > 推（accept 与 x_kill 互斥：accept 蕴含 x_adv 蕴含 !x_kill） ----
      if (x_valid && x_kill)
        x_valid <= 1'b0;
      else if (accept) begin
        x_valid <= 1'b1;
        x_aop   <= a_aop;
        x_addr  <= a_addr;
        x_sk    <= src_k;
        x_pd    <= uop[`UOP_PD];
        x_rdwen <= uop[`UOP_RD_WEN];
        x_rob   <= uop[`UOP_ROB];
        x_sc    <= a_issc;
        x_push  <= (a_isst || (a_issc && ll_bit)) && !a_ale;
        x_ale   <= a_ale;
        x_ld    <= a_isld;
        x_uc    <= a_uc;
        x_res   <= (a_issc && ll_bit) ? 32'd1 : 32'd0;
      end else if (x_adv)
        x_valid <= 1'b0;

      // ---- v5：前递字每拍寄存化（y 内 load 等待期间；源全是本地寄存器，
      //      rvalid→result 仅余一级 AND-OR 字节选择，mux 链全部寄存器前完成） ----
      if (y_valid && y_is_load && !y_killed) begin
        y_fwd      <= fwd_word_c;
        y_fwd_mask <= fwd_mask_c;
      end

      // ---- y 槽处理（完成/推进；与下方 x→y 装载可同拍，后者覆盖 y_* 字段） ----
      if (y_valid) begin
        case (y_state)
          Y_AR: begin
            if (ls_arvalid) begin
              if (ar_hs) begin
                ls_arvalid <= 1'b0;
                y_state    <= Y_R;
                y_killed   <= y_kill;    // 握手已完成，事务必须收 R，标记丢弃
              end else if (y_kill) begin
                ls_arvalid <= 1'b0;      // 未握手可直接撤回
                y_valid    <= 1'b0;
              end
            end else begin
              // AR 未发：drain 互斥等窗（I6'）。
              // I13'（v5.1）：UC/LL 立即发 AR、不驻留——原"等更老未完成 store"
              // 门存在死锁环（UC load 驻 y ← 更老 store 等 commit ← ROB head 的
              // load 卡 x ← y 被占；func n42/n44 实锤）。存储序改由前递合并
              // 对 UC/LL 同样生效保证（sb 内更老 store 字节并入读数据）。
              if (y_kill) begin
                y_valid <= 1'b0;         // 无 AR 可撤，直接清
              end else if (ar_gate)
                ls_arvalid <= 1'b1;
            end
          end
          Y_R: begin
            if (y_kill) y_killed <= 1'b1;
            if (ls_rvalid) begin
              if (y_killed || y_kill) begin
                y_valid  <= 1'b0;        // 丢弃投机数据
                y_killed <= 1'b0;
              end else if (done_hold) begin
                // skid 占用：锁存结果转 Y_DN 等放行（ll_set 时序保持 rvalid 拍，I8）
                y_res   <= ld_extract(y_aop, y_ld_data, y_addr[1:0]);
                y_state <= Y_DN;
                if (y_aop == `AOP_LL) ll_set <= 1'b1;
              end else begin
                result  <= ld_extract(y_aop, y_ld_data, y_addr[1:0]);
                done    <= 1'b1;
                // store 无目的寄存器：pd 归 0，防 PRF 误写/误进 skid（I11）
                done_pd <= y_rdwen ? y_pd : 6'd0;
                done_rob <= y_rob;
                done_excpt <= `EXC_NONE;
                done_badv  <= 32'b0;
                if (y_aop == `AOP_LL) ll_set <= 1'b1;
                y_valid <= 1'b0;
              end
            end
          end
          Y_DN: begin
            if (y_kill) begin
              y_valid <= 1'b0;           // 被杀：无 done 无 push
            end else if (!done_hold) begin
              done      <= 1'b1;
              result    <= y_res;
              done_pd   <= y_rdwen ? y_pd : 6'd0;   // I11
              done_rob  <= y_rob;
              done_excpt <= y_ale ? `EXC_ALE : `EXC_NONE;
              done_badv  <= y_ale ? y_addr : 32'b0;
              if (y_sc) sc_clear <= 1'b1;           // sc_clear 仅 sc 的 done 拍（I8）
              y_valid <= 1'b0;
            end
          end
          default: y_state <= Y_AR;
        endcase
      end

      // ---- x→y 装载（y 完成让位同拍填入；字段覆盖安全，done 脉冲不受影响） ----
      if (x_adv) begin
        y_valid  <= 1'b1;
        y_aop    <= x_aop;
        y_addr   <= x_addr;
        y_sk     <= x_sk;
        y_pd     <= x_pd;
        y_rdwen  <= x_rdwen;
        y_rob    <= x_rob;
        y_sc     <= x_sc;
        y_push   <= x_push;
        y_ale    <= x_ale;
        y_uc     <= x_uc;
        y_res    <= x_res;
        y_killed <= 1'b0;
        if (x_ld && !x_ale) begin
          y_state    <= Y_AR;
          ls_araddr  <= {x_addr[31:2], 2'b00};   // AXI size=4B，按字对齐发
          // cacheable load 立即发（须与 drain 互斥，I6'）；
          // uc/LL 或 drain 占用窗则 Y_AR 驻留等门开
          if (!(x_uc || (x_aop == `AOP_LL)) && ar_gate)
            ls_arvalid <= 1'b1;
        end else begin
          y_state    <= Y_DN;                    // store/sc/ALE：下一拍出 done
        end
      end
    end
  end

  // ---------------- store buffer + AXI 写通道 ----------------
  wire pop = wr_act && ls_bvalid;   // B 无 bready 端口，视为一拍脉冲必须接收

  integer i;
  integer j;
  reg [1:0] idx;
  // flush 压缩暂存
  reg [31:0] c_addr [0:`SB_DEPTH-1];
  reg [31:0] c_data [0:`SB_DEPTH-1];
  reg [3:0]  c_strb [0:`SB_DEPTH-1];
  reg [4:0]  c_rob  [0:`SB_DEPTH-1];
  reg        c_gnt  [0:`SB_DEPTH-1];
  reg        keep, granting;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sb_valid   <= {`SB_DEPTH{1'b0}};
      sb_granted <= {`SB_DEPTH{1'b0}};
      sb_hp      <= 2'b0;
      sb_cnt     <= 3'b0;
      wr_act     <= 1'b0;
      ls_awvalid <= 1'b0;
      ls_awaddr  <= 32'b0;
      ls_wvalid  <= 1'b0;
      ls_wdata   <= 32'b0;
      ls_wstrb   <= 4'b0;
    end else begin
      // 写握手进度（两分支通用）
      if (ls_awvalid && ls_awready) ls_awvalid <= 1'b0;
      if (ls_wvalid && ls_wready)   ls_wvalid  <= 1'b0;

      if (exc_flush || bru_flush) begin
        // ---------------- flush：压缩保序，丢弃未授权被杀项 ----------------
        /* verilator lint_off BLKSEQ */  // j/idx/keep/c_* 为过程内组合暂存，阻塞赋值有意为之
        j = 0;
        for (i = 0; i < `SB_DEPTH; i = i + 1) begin
          idx = sb_hp + i[1:0];
          granting = sb_valid[idx] && !(pop && (i == 0)) &&
                     ((sb_commit0 && (sb_rob[idx] == sb_commit_rob0)) ||
                      (sb_commit1 && (sb_rob[idx] == sb_commit_rob1)));
          keep = sb_valid[idx] && !(pop && (i == 0))
               && (sb_granted[idx] || granting
                   || !(exc_flush || in_range(sb_rob[idx], bru_rob, rob_tail_cur)));
          if (keep) begin
            c_addr[j] = sb_addr[idx];
            c_data[j] = sb_data[idx];
            c_strb[j] = sb_strb[idx];
            c_rob[j]  = sb_rob[idx];
            c_gnt[j]  = sb_granted[idx] || granting;
            j = j + 1;
          end
        end
        for (i = 0; i < `SB_DEPTH; i = i + 1) begin
          idx = sb_hp + i[1:0];
          if (i < j) begin
            sb_valid[idx]   <= 1'b1;
            sb_granted[idx] <= c_gnt[i];
            sb_addr[idx]    <= c_addr[i];
            sb_data[idx]    <= c_data[i];
            sb_strb[idx]    <= c_strb[i];
            sb_rob[idx]     <= c_rob[i];
          end else begin
            sb_valid[idx]   <= 1'b0;
            sb_granted[idx] <= 1'b0;
          end
        end
        // push 追加在压缩后尾部（push 与被杀互斥，见 y 槽 Y_DN）
        if (push) begin
          idx = sb_hp + j[1:0];
          sb_valid[idx]   <= 1'b1;
          sb_granted[idx] <= 1'b0;
          sb_addr[idx]    <= y_addr;
          sb_data[idx]    <= st_data(y_aop, y_sk);
          sb_strb[idx]    <= st_strb(y_aop, y_addr[1:0]);
          sb_rob[idx]     <= y_rob;
          sb_cnt <= j[2:0] + 3'd1;
        end else begin
          sb_cnt <= j[2:0];
        end
        // flush 与 B 同拍：在途写属于已提交 store，正常收尾
        if (pop) begin
          wr_act <= 1'b0;
        end
        /* verilator lint_on BLKSEQ */
      end else begin
        // ---------------- 正常拍：pop / grant / push / 发写 ----------------
        if (pop) begin
          sb_valid[sb_hp]   <= 1'b0;
          sb_granted[sb_hp] <= 1'b0;
          sb_hp             <= sb_hp + 2'd1;
          wr_act            <= 1'b0;
        end
        for (i = 0; i < `SB_DEPTH; i = i + 1) begin
          if (sb_valid[i] &&
              ((sb_commit0 && (sb_rob[i] == sb_commit_rob0)) ||
               (sb_commit1 && (sb_rob[i] == sb_commit_rob1))))
            sb_granted[i] <= 1'b1;
        end
        if (push) begin
          // 注：pop 与 push 同拍时，新项落 hp+cnt（= 弹出后尾部），位置正确
          /* verilator lint_off BLKSEQ */  // idx 为过程内组合暂存
          idx = sb_hp + sb_cnt[1:0];
          /* verilator lint_on BLKSEQ */
          sb_valid[idx]   <= 1'b1;
          sb_granted[idx] <= 1'b0;
          sb_addr[idx]    <= y_addr;
          sb_data[idx]    <= st_data(y_aop, y_sk);
          sb_strb[idx]    <= st_strb(y_aop, y_addr[1:0]);
          sb_rob[idx]     <= y_rob;
        end
        sb_cnt <= sb_cnt + (push ? 3'd1 : 3'd0) - (pop ? 3'd1 : 3'd0);

        // 头项已授权且无在途写 -> 发 AW/W（同拍给出，单 outstanding）
        // v5：与 load AR 互斥（I6'）——AR 挂起或本拍有 load 入 y 则 drain 让路；
        // 反向由 ar_gate 保证（drain 在途/将发不发 AR），两侧不可能同拍撞 dcache
        if (!wr_act && sb_valid[sb_hp] && sb_granted[sb_hp] && !ls_arvalid
            && !(x_adv && x_ld && !x_ale)) begin
          wr_act     <= 1'b1;
          ls_awvalid <= 1'b1;
          ls_awaddr  <= sb_addr[sb_hp];
          ls_wvalid  <= 1'b1;
          ls_wdata   <= sb_data[sb_hp];
          ls_wstrb   <= sb_strb[sb_hp];
        end
      end
    end
  end

  // ---------------- 输出 ----------------
  // I3：block_load = buffer 非空 || x/y 槽内有将入 buffer 的 store（C6 保守）
  assign block_load = (|sb_valid) || (x_valid && x_push) || (y_valid && y_push);
  // I9：noaccept = 槽占用且不推进 || store 门控无余量（IQ 上拍结构门控，
  // 下拍 accept 的一拍提前语义，与 issue_queue.v 注释一致）
  assign noaccept    = (x_valid && !x_adv) || !store_gate;
  // I2：noaccept_ld 只反映 x/y 槽占用，不含 sb 状态——
  // 否则"sb 满（未提交投机 store）+ ROB 头是 load"构成死锁（n13 实证）：
  // load 发不出 → store 无法提交授权 → sb 永不排空。
  // load 与更老在 sb store 的序由 IQ 侧 C6 独立保证。
  assign noaccept_ld = (x_valid && !x_adv);
  // ---- C6 幻影项（v3 修补）：store 离 IQ（older_st 失效）到入 sb（C6 接管）
  // 之间隔了 x→y 两拍，期间 C6 的 sb 检查看不见它——更老 store 未 drain 时
  // 年轻 load 会抢到 AR 读陈旧行（coremark strchr st.b/ld.bu 实证）。
  // 把 x/y 中最老的将入 sb 的 store 以"未授权幻影项"注入第一个空槽的观测口：
  // IQ 的 C6 年龄逻辑原样适用（g=0，tag 真实）。被遮的 x store 比 y 幻影年轻，
  // 任何比它年轻的 load 必然也被 y 幻影挡住；sb 满时不注入——此时能被 C6 放行的
  // load 必老于全部 sb store，而 x/y store 更年轻（C7 保序），无需幻影。
  wire        ph_v   = (x_valid && x_push) || (y_valid && y_push);
  wire [4:0]  ph_rob = (y_valid && y_push) ? y_rob : x_rob;
  wire [`SB_DEPTH-1:0] ph_inv  = ~sb_valid;
  wire [`SB_DEPTH-1:0] ph_mask = ph_v ? (ph_inv & (~ph_inv + {{`SB_DEPTH-1{1'b0}}, 1'b1}))
                                      : {`SB_DEPTH{1'b0}};
  assign sb_v_o   = sb_valid | ph_mask;
  assign sb_g_o   = sb_granted;          // 幻影项 g=0（未授权，走 C6 年龄逻辑）
  // 拍平各项 ROB 标签供 IQ 做年龄比较（幻影槽位注入幻影 tag）
  genvar g_sb;
  generate
    for (g_sb = 0; g_sb < `SB_DEPTH; g_sb = g_sb + 1) begin : g_sb_rob
      assign sb_rob_o[g_sb*5 +: 5] = ph_mask[g_sb] ? ph_rob : sb_rob[g_sb];
    end
  endgenerate
  // I9：busy = x/y 占用 | AXI 写在途 | 有已授权待发项 | store buffer 满
  assign busy = x_valid || y_valid || wr_act || (|(sb_valid & sb_granted)) || (&sb_valid);

  // ---- tb_r.v 层次化探针兼容别名（旧串行 FSM 命名 → y 槽，仅供仿真探针） ----
  /* verilator lint_off UNUSEDSIGNAL */
  wire [31:0] cur_addr  = y_addr;
  wire [5:0]  cur_aop   = y_aop;
  wire [4:0]  cur_rob   = y_rob;
  wire [31:0] cur_sk    = y_sk;
  wire        killed    = y_killed;
  wire        kill_cond = y_kill;
  wire [1:0]  m_state   = y_state;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
