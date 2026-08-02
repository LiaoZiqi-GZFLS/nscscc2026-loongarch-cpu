// ============================================================================
// lsu.v — LA32R-2S 访存单元（lane0 专属）+ 4 深 store buffer
// 见 SPEC.md §4.4 / §3-C6。纯 Verilog-2001。
//
// 要点：
//  - 地址 = src_j + UOP_IMM；对齐检查，违例 -> done_excpt=EXC_ALE, 不发 AXI
//  - load: AR->R，按 AOP 做字节/半字提取与符号/零扩展；LL 同 LDW 并 ll_set 一拍
//  - store: EX 拍算好 {addr,data,wstrb,rob_tag} 入 store buffer，
//    等 sb_commit 授权（rob_tag 匹配）后按 buffer 顺序发 AW/W，B 后弹出
//  - SC: 检查 ll_bit，成功走 store 流程且 result=1；失败不写内存 result=0；
//    两种情况均 sc_clear 一拍
//  - block_load = store buffer 非空（含即将入 buffer 的未完成 store，C6 保守）
//  - bru_flush: 丢弃 ROB tag 落在 (bru_rob, rob_tail_cur) 开区间的未授权项
//    exc_flush: 丢弃全部未授权项（已授权项不受 flush 影响）
//  - flush 同时杀死在途投机 load（AR 未握手直接撤，R 阶段等数据返回后丢弃）
//  - AXI 单 outstanding
//  - busy = 主 FSM 忙 | AXI 写在途 | 有已授权待发项 | store buffer 满
//    （buffer 满纳入 busy 属于实现 safeguard：无 sb_full 端口，防溢出）
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
  output noaccept,                         // 结构冒险(store)：主 FSM 忙或 buffer 满，下拍不能 accept
  output noaccept_ld,                      // 结构冒险(load)：仅主 FSM 忙（load 不占 sb）
  output [`SB_DEPTH-1:0]  sb_v_o,          // store buffer 有效位（C6 精确化）
  output [`SB_DEPTH*5-1:0] sb_rob_o,       // store buffer 各项 ROB 标签
  output [`SB_DEPTH-1:0]  sb_g_o,          // store buffer 各项已提交授权（C6 补洞：已提交 store 必阻塞一切 load）
  // LLbit 交互（csr_file）
  output reg ll_set, output reg sc_clear, input ll_bit,
  // 完成输出
  output reg done, output reg [31:0] result,
  output reg [5:0] done_pd, output reg [4:0] done_rob,
  output reg [5:0] done_excpt, output reg [31:0] done_badv,
  input exc_flush, input bru_flush, input [4:0] bru_rob, input [4:0] rob_tail_cur
);

  // ---------------- 主 FSM 状态 ----------------
  localparam S_IDLE = 2'd0;
  localparam S_AR   = 2'd1;
  localparam S_R    = 2'd2;
  localparam S_DN   = 2'd3;

  reg [1:0]  m_state;
  reg [5:0]  cur_aop;
  reg [31:0] cur_addr;
  reg [31:0] cur_sk;      // store 数据（SC 同）
  reg        cur_rdwen;   // 集成修复：store 不写 PRF（done_pd 必须归零）
  reg [5:0]  cur_pd;
  reg [4:0]  cur_rob;
  reg        cur_push;    // 本操作完成后需要入 store buffer
  reg        cur_sc;
  reg [31:0] cur_res;
  reg [5:0]  cur_exc;
  reg        killed;      // 在途 load 被 flush 杀死（等 R 丢弃）

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

  // ---------------- 接收拍组合译码 ----------------
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
  wire accept = req && (m_state == S_IDLE) && !a_kill;

  // 在途操作的 kill 条件
  wire kill_cond = exc_flush || (bru_flush && in_range(cur_rob, bru_rob, rob_tail_cur));

  // store 入 buffer 脉冲（DN 拍且未被杀）
  wire push = (m_state == S_DN) && cur_push && !killed && !kill_cond;

  // ---------------- 主 FSM ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_state   <= S_IDLE;
      cur_aop   <= 6'b0;
      cur_addr  <= 32'b0;
      cur_sk    <= 32'b0;
      cur_pd    <= 6'b0;
      cur_rdwen <= 1'b0;
      cur_rob   <= 5'b0;
      cur_push  <= 1'b0;
      cur_sc    <= 1'b0;
      cur_res   <= 32'b0;
      cur_exc   <= `EXC_NONE;
      killed    <= 1'b0;
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

      case (m_state)
        S_IDLE: begin
          if (accept) begin
            cur_aop  <= a_aop;
            cur_addr <= a_addr;
            cur_sk   <= src_k;
            cur_pd   <= uop[`UOP_PD];
            cur_rdwen<= uop[`UOP_RD_WEN];
            cur_rob  <= uop[`UOP_ROB];
            cur_sc   <= a_issc;
            cur_push <= (a_isst || (a_issc && ll_bit)) && !a_ale;
            killed   <= 1'b0;
            cur_exc  <= `EXC_NONE;
            if (a_ale) begin
              // 对齐错：不发 AXI，直接完成并报 ALE
              cur_exc <= `EXC_ALE;
              cur_res <= 32'b0;
              m_state <= S_DN;
            end else if (a_isld) begin
              ls_arvalid <= 1'b1;
              ls_araddr  <= {a_addr[31:2], 2'b00};   // AXI size=4B，按字对齐发
              m_state    <= S_AR;
            end else begin
              // store / sc：EX 拍算好，DN 拍入 buffer（SC 失败 cur_push=0）
              cur_res <= (a_issc && ll_bit) ? 32'd1 : 32'd0;
              m_state <= S_DN;
            end
          end
        end

        S_AR: begin
          if (ls_arready) begin
            ls_arvalid <= 1'b0;
            m_state    <= S_R;
            killed     <= kill_cond;    // 握手已完成，事务必须收 R，标记丢弃
          end else if (kill_cond) begin
            ls_arvalid <= 1'b0;         // 未握手可直接撤回
            m_state    <= S_IDLE;
          end
        end

        S_R: begin
          if (kill_cond) killed <= 1'b1;
          if (ls_rvalid) begin
            if (killed || kill_cond) begin
              m_state <= S_IDLE;        // 丢弃投机数据
              killed  <= 1'b0;
            end else begin
              cur_res <= ld_extract(cur_aop, ls_rdata, cur_addr[1:0]);
              if (cur_aop == `AOP_LL) ll_set <= 1'b1;
              m_state <= S_DN;
            end
          end
        end

        S_DN: begin
          m_state <= S_IDLE;
          killed  <= 1'b0;
          if (!killed && !kill_cond) begin
            done      <= 1'b1;
            result    <= cur_res;
            // store 无目的寄存器：pd 归 0，防 PRF 误写/误进 skid
            done_pd   <= cur_rdwen ? cur_pd : 6'd0;
            done_rob  <= cur_rob;
            done_excpt <= cur_exc;
            done_badv <= (cur_exc == `EXC_ALE) ? cur_addr : 32'b0;
            if (cur_sc) sc_clear <= 1'b1;
          end
        end

        default: m_state <= S_IDLE;
      endcase
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
        // push 追加在压缩后尾部（push 与被杀互斥，见主 FSM）
        if (push) begin
          idx = sb_hp + j[1:0];
          sb_valid[idx]   <= 1'b1;
          sb_granted[idx] <= 1'b0;
          sb_addr[idx]    <= cur_addr;
          sb_data[idx]    <= st_data(cur_aop, cur_sk);
          sb_strb[idx]    <= st_strb(cur_aop, cur_addr[1:0]);
          sb_rob[idx]     <= cur_rob;
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
          sb_addr[idx]    <= cur_addr;
          sb_data[idx]    <= st_data(cur_aop, cur_sk);
          sb_strb[idx]    <= st_strb(cur_aop, cur_addr[1:0]);
          sb_rob[idx]     <= cur_rob;
        end
        sb_cnt <= sb_cnt + (push ? 3'd1 : 3'd0) - (pop ? 3'd1 : 3'd0);

        // 头项已授权且无在途写 -> 发 AW/W（同拍给出，单 outstanding）
        if (!wr_act && sb_valid[sb_hp] && sb_granted[sb_hp]) begin
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
  // block_load：buffer 非空，或主 FSM 中尚有将入 buffer 的 store（C6 保守）
  assign block_load = (|sb_valid) || ((m_state != S_IDLE) && cur_push);
  // noaccept：accept 条件为 (m_state==S_IDLE)，buffer 满时 store 入不了
  // → IQ 须在上拍结构门控（发射寄存器化有一拍延迟，busy 来不及）
  assign noaccept = (m_state != S_IDLE) || (&sb_valid);
  // noaccept_ld：load 不占用 store buffer，sb 满不应阻塞 load——
  // 否则"sb 满（未提交投机 store）+ ROB 头是 load"构成死锁（n13 实证）：
  // load 发不出 → store 无法提交授权 → sb 永不排空。
  // load 与更老在 sb store 的序由 IQ 侧 C6 独立保证。
  assign noaccept_ld = (m_state != S_IDLE);
  assign sb_v_o   = sb_valid;
  assign sb_g_o   = sb_granted;
  // 拍平各项 ROB 标签供 IQ 做年龄比较
  genvar g_sb;
  generate
    for (g_sb = 0; g_sb < `SB_DEPTH; g_sb = g_sb + 1) begin : g_sb_rob
      assign sb_rob_o[g_sb*5 +: 5] = sb_rob[g_sb];
    end
  endgenerate
  assign busy = (m_state != S_IDLE) || wr_act || (|(sb_valid & sb_granted)) || (&sb_valid);

endmodule
