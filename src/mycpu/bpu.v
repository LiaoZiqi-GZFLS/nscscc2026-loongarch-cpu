// ============================================================================
// bpu.v — v3 分支预测器：BTB + GShare + RAS
// 见 SPEC.md §8.8。纯 Verilog-2001。
//
// 组成：
//  - BTB：128 项直接映射【行粒度】（index=pc[10:4]，tag=pc[31:11]），
//    每项 {valid, tag, offset[1:0], cat[1:0], target[31:0]}——
//    记录"该行内第一个预测 taken 的分支"位置与类别。异步读（LUTRAM 推断），
//    req 拍组合查询、打拍后与 icache resp（固定 1 拍 / miss 冻结）严格对齐
//  - GShare：PHT 256×2bit 饱和计数，index = GHR ^ pc[9:2]；
//    GHR 8bit【非投机】——EX  bru 解析拍才移入实际方向（零回滚复杂度；
//    循环回边场景下一次迭代预测时历史已就位，准确率代价小）
//  - RAS：8 深。call 预测拍压栈（返回地址=分支pc+4），ret 预测拍弹栈给目标。
//    投机操作【误预测不修复】：栈污染只影响 ret 目标预测，EX 验证兜底正确性。
//    【空栈禁预测】：cat==RET 且 ras_cnt==0 时 q_pred_taken=0——BTB 行粒度
//    单槽会被同行后写覆盖（call 项被 ret 项顶掉），首次 call BTB miss 不压栈，
//    空栈弹出的 x 目标会把 pc_reg 带飞（t2_branch 实证）
//
// 更新策略（EX bru 解析拍驱动）：
//  - taken 分支写 BTB（新分配 / 修正目标或类别）；not-taken 不删（PHT 学习）
//  - cond 分支按实际方向步进 PHT；任何分支解析移 GHR
// 预测使用（frontend req 拍）：
//  - q_pred_taken = hit && (cat!=COND || pht[hash][1])；RET 目标取 RAS 栈顶
// ============================================================================
`include "la32_defs.vh"

module bpu(
  input              clk,
  input              rst_n,
  // 查询（req 拍组合；q_pc 为 16B 行对齐地址）
  input      [31:0]  q_pc,
  output             q_pred_taken,
  output     [1:0]   q_offset,
  output     [31:0]  q_target,
  output     [1:0]   q_cat,
  // RAS 投机操作（frontend resp 截断拍）
  input              ras_push,
  input      [31:0]  ras_push_addr,
  input              ras_pop,
  // EX 更新（bru 解析拍：无论预测对错都更新）
  input              u_valid,
  input      [31:0]  u_pc,
  input      [1:0]   u_cat,
  input              u_taken,
  input      [31:0]  u_target
);

  // ---------------- BTB ----------------
  reg [20:0] btb_tag [0:127];
  reg [1:0]  btb_off [0:127];
  reg [1:0]  btb_cat [0:127];
  reg [31:0] btb_tgt [0:127];
  reg [127:0] btb_valid;

  // ---------------- GShare ----------------
  reg [1:0] pht [0:255];
  reg [7:0] ghr;

  // ---------------- RAS ----------------
  reg [31:0] ras [0:7];
  reg [2:0]  ras_top;
  reg [3:0]  ras_cnt;

  // ---------------- 查询（组合） ----------------
  wire [6:0]  q_idx   = q_pc[10:4];
  wire        q_hit   = btb_valid[q_idx] && (btb_tag[q_idx] == q_pc[31:11]);
  wire [1:0]  q_cat_w = btb_cat[q_idx];
  wire [7:0]  q_hash  = ghr ^ q_pc[9:2];
  wire        q_dir   = pht[q_hash][1];           // 2bit 高位=预测方向

  assign q_cat        = q_cat_w;
  assign q_offset     = btb_off[q_idx];
  assign q_target     = (q_cat_w == `BC_RET) ? ras[ras_top] : btb_tgt[q_idx];
  assign q_pred_taken = q_hit && ((q_cat_w != `BC_COND) || q_dir)
                      && ((q_cat_w != `BC_RET) || (ras_cnt != 4'd0));

  // ---------------- 更新 ----------------
  wire [6:0] u_idx  = u_pc[10:4];
  wire [7:0] u_hash = ghr ^ u_pc[9:2];            // 与查询同源（旧 GHR）
  // RAS 写索引显式 3bit 截断：memory 索引表达式按 32bit integer 求值时
  // ras_top+1=8 越界写被丢弃（iverilog v11 实测），v13 按地址宽截断正常——
  // 仿真器行为分歧根源；显式 wire 截断后两域一致（Stage 31i 破案）
  wire [2:0] ras_widx = ras_top + 3'd1;

  integer k;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      btb_valid <= 128'd0;
      ghr       <= 8'd0;
      ras_top   <= 3'd0;
      ras_cnt   <= 4'd0;
      for (k = 0; k < 256; k = k + 1) pht[k] = 2'b01;   // 弱 not-taken；复位循环用阻塞赋值：verilator BLKLOOPINIT 限制，复位域语义等价
    end else begin
      if (u_valid) begin
        // GHR：移入实际方向（非投机，EX 域）
        ghr <= {ghr[6:0], u_taken};
        // PHT：仅条件分支，饱和计数步进
        if (u_cat == `BC_COND) begin
          if (u_taken)
            pht[u_hash] <= (pht[u_hash] == 2'b11) ? 2'b11 : pht[u_hash] + 2'd1;
          else
            pht[u_hash] <= (pht[u_hash] == 2'b00) ? 2'b00 : pht[u_hash] - 2'd1;
        end
        // BTB：taken 才分配/修正（新分支 or 目标、类别修正）
        if (u_taken) begin
          btb_valid[u_idx] <= 1'b1;
          btb_tag[u_idx]   <= u_pc[31:11];
          btb_off[u_idx]   <= u_pc[3:2];
          btb_cat[u_idx]   <= u_cat;
          btb_tgt[u_idx]   <= u_target;
        end
      end
      // RAS 投机压/弹（与 u_valid 同拍可并存，无端口冲突）
      if (ras_push) begin
        ras[ras_widx] <= ras_push_addr;
        ras_top <= ras_top + 3'd1;
        ras_cnt <= (ras_cnt == 4'd8) ? 4'd8 : ras_cnt + 4'd1;  // 溢出环形覆盖
      end else if (ras_pop && (ras_cnt != 4'd0)) begin
        ras_top <= ras_top - 3'd1;
        ras_cnt <= ras_cnt - 4'd1;
      end
    end
  end

endmodule
