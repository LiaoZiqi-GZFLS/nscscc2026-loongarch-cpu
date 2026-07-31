// ============================================================================
// ex_mdu.v — 多周期乘除单元（lane0，非阻塞，同拍至多 1 个运算在飞）
// SPEC §4.6：
//   MUL/MULH/MULHU : 4 拍延迟（v2.2 流水化：操作数拍 + 乘积拍 + 选择 + 完成）——
//     33×33 单乘法器（{hu?0:a[31],a} 统一有/无符号扩展，消除 DSP 输出 MUX；
//     synth_xilinx -retime 可将两级寄存器吸入 DSP48E1 AREG/BREG/MREG/PREG，
//     消除 reg→DSP→MUX→reg 的 ~6-7ns 最坏路径，冲 133MHz+）
//   DIV/DIVU/MOD/MODU : 恢复余数迭代除法器，34 拍（32 迭代 + 符号整理 + 完成）
// 除零行为（LA32r 手册 div.w/div.wu/mod.w/mod.wu 不产外例外，结果约定）：
//   恢复余数除法器在 divisor==0 时自然收敛到手册约定值——
//   商(无符号)=32'hFFFF_FFFF，余=被除数；
//   有符号商按被除数符号取 32'hFFFF_FFFF(-1) 或 32'd1，余=被除数。
//   （假设：与手册"商全1/余被除数"一致；tb 验证并注明）
// 溢出 INT_MIN/-1：商自然回绕为 INT_MIN、余 0（与手册一致）。
// flush：exc_flush/bru_flush 直接丢弃在飞运算（不会给已 flush 的 ROB 项写 done）。
//   简化假设：顶层保证 serial/bru 时序下无需按 ROB tag 范围精确杀伤。
// busy 输出 = 在飞 | 本拍 req（堵住 IQ 发射拍与 busy 寄存器化之间的一拍空洞）。
// ============================================================================
`include "la32_defs.vh"

module ex_mdu(
  input clk, input rst_n,
  input req, input [`UOP_W-1:0] uop, input [31:0] src_j, input [31:0] src_k,
  output busy,
  output reg done, output reg [31:0] result,
  output reg [5:0] done_pd, output reg [4:0] done_rob,
  input exc_flush, input bru_flush,
  input [4:0] bru_rob, input [4:0] rob_tail_cur
);

  // ROB 环形区间判断：tag ∈ (from, tail) 开区间（与 lsu 同一语义）
  function in_range;
    input [4:0] tag;
    input [4:0] from;
    input [4:0] tail;
    reg [4:0] d1, d2;
    begin
      d1 = tag - from;
      d2 = tail - from;
      in_range = (d2 != 5'd0) && (d1 != 5'd0) && (d1 < d2);
    end
  endfunction



  // ---------------- 请求解码 ----------------
  wire [5:0] aluop   = uop[`UOP_ALUOP];
  wire       is_mul  = (aluop == `AOP_MUL) | (aluop == `AOP_MULH) | (aluop == `AOP_MULHU);
  wire       sign_op = (aluop == `AOP_MUL) | (aluop == `AOP_MULH)
                     | (aluop == `AOP_DIV) | (aluop == `AOP_MOD);

  // ---------------- 状态 ----------------
  reg        busy_r;
  reg [5:0]  cnt;            // 剩余拍数：mul=3, div=34
  reg [5:0]  op_r;           // aluop 锁存
  reg [5:0]  pd_r;
  reg [4:0]  rob_r;
  // 乘法（v2.2 两级流水：mul_a/mul_b 操作数拍 → prod 乘积拍）
  reg [31:0] mul_a, mul_b;
  reg        mul_hu_r;         // 1=无符号扩展（MULHU）
  reg [63:0] prod;
  // 除法
  reg [32:0] rem;            // 部分余数（不变式：每步后 rem < divisor，故 rem[32] 恒 0）
  reg [31:0] q;              // 被除数移位寄存器 / 商逐位生成
  reg [31:0] dvs;            // |除数|
  reg        q_neg, r_neg;   // 商/余符号（有符号运算）

  assign busy = busy_r | req;

  // 集成修复：误预测只杀"比分支年轻"的在飞运算；更老的必须存活，
  // 否则"头部长延迟 MDU + 年轻分支反复误预测"构成 livelock
  wire kill_flight = exc_flush |
                     (bru_flush & busy_r & in_range(rob_r, bru_rob, rob_tail_cur));

  // 接受请求时的操作数预处理（有符号取绝对值）
  wire        a_neg  = sign_op & src_j[31];
  wire        b_neg  = sign_op & src_k[31];
  wire [31:0] a_abs  = a_neg ? (~src_j + 32'd1) : src_j;
  wire [31:0] b_abs  = b_neg ? (~src_k + 32'd1) : src_k;

  // 64 位乘积（v2.2：33×33 单乘法器，符号/无符号统一为 33bit 有符号扩展；
  // 低 32 位有/无符号相同，高 32 位两种扩展各自正确）
  wire signed [32:0] mul_ae = {(mul_hu_r ? 1'b0 : mul_a[31]), mul_a};
  wire signed [32:0] mul_be = {(mul_hu_r ? 1'b0 : mul_b[31]), mul_b};
  wire signed [65:0] prod66  = mul_ae * mul_be;   // 取 [63:0]：64bit 正确积

  // 除法单步迭代（恢复余数）
  wire [32:0] rem_shift = {rem[31:0], q[31]};
  wire        step_ge   = (rem_shift >= {1'b0, dvs});
  wire [32:0] rem_next  = step_ge ? (rem_shift - {1'b0, dvs}) : rem_shift;
  wire [31:0] q_next    = {q[30:0], step_ge};

  // 符号整理（有符号：商符号 = 两操作数异号；余符号 = 被除数符号）
  wire [31:0] q_signadj = q_neg ? (~q + 32'd1) : q;
  wire [31:0] r_signadj = r_neg ? (~rem[31:0] + 32'd1) : rem[31:0];

  wire        op_is_mul  = (op_r == `AOP_MUL) | (op_r == `AOP_MULH) | (op_r == `AOP_MULHU);
  wire        op_want_rem= (op_r == `AOP_MOD) | (op_r == `AOP_MODU);

  // 未用位段/不变式位（rem[32] 恒 0，见头部注释）——显式汇聚消除 lint 噪音
  wire        unused_ok  = &{1'b0, uop[`UOP_SPARE], uop[`UOP_EXCPT], uop[`UOP_CKPT],
                             uop[`UOP_BR_TYPE], uop[`UOP_SERIAL], uop[`UOP_RD_ARCH],
                             uop[`UOP_RD_WEN], uop[`UOP_PK_RDY], uop[`UOP_PJ_RDY],
                             uop[`UOP_PK], uop[`UOP_PJ], uop[`UOP_FU], uop[`UOP_IMM],
                             uop[`UOP_PC], rem[32]};

  // ---------------- 时序 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_r  <= 1'b0;
      cnt     <= 6'd0;
      op_r    <= 6'd0;
      pd_r    <= 6'd0;
      rob_r   <= 5'd0;
      prod    <= 64'd0;
      rem     <= 33'd0;
      q       <= 32'd0;
      dvs     <= 32'd0;
      q_neg   <= 1'b0;
      r_neg   <= 1'b0;
      done    <= 1'b0;
      result  <= 32'd0;
      done_pd <= 6'd0;
      done_rob<= 5'd0;
      mul_a   <= 32'd0;
      mul_b   <= 32'd0;
      mul_hu_r<= 1'b0;
    end else if (kill_flight) begin
      // 例外=全杀；误预测=只杀更年轻的在飞运算，本拍不产生 done
      busy_r <= 1'b0;
      cnt    <= 6'd0;
      done   <= 1'b0;
    end else begin
      done <= 1'b0;

      if (req && !busy_r) begin
        // 接受新运算
        busy_r <= 1'b1;
        op_r   <= aluop;
        pd_r   <= uop[`UOP_PD];
        rob_r  <= uop[`UOP_ROB];
        if (is_mul) begin
          cnt     <= 6'd4;          // v2.2：操作数拍+乘积拍+选择+完成 = 4 拍
          mul_a   <= src_j;
          mul_b   <= src_k;
          mul_hu_r<= (aluop == `AOP_MULHU);
        end else begin
          cnt   <= 6'd34;
          rem   <= 33'd0;
          q     <= a_abs;
          dvs   <= b_abs;
          q_neg <= sign_op & (a_neg ^ b_neg);
          r_neg <= sign_op & a_neg;
        end
      end else if (busy_r) begin
        if (cnt == 6'd1) begin
          // 完成拍：统一广播，写 PRF 后唤醒消费者（N4）
          busy_r   <= 1'b0;
          cnt      <= 6'd0;
          done     <= 1'b1;
          done_pd  <= pd_r;
          done_rob <= rob_r;
          if (op_is_mul)
            result <= (op_r == `AOP_MUL) ? prod[31:0] : prod[63:32];
          else
            result <= op_want_rem ? r_signadj : q_signadj;
        end else begin
          cnt <= cnt - 6'd1;
          if (op_is_mul && cnt == 6'd4) begin
            // 接受后第 1 拍：锁存 64bit 乘积（DSP 前后各一拍，retime 吸入）
            prod <= prod66[63:0];
          end
          if (!op_is_mul && cnt >= 6'd3) begin
            // 32 次迭代：cnt = 34 .. 3
            rem <= rem_next;
            q   <= q_next;
          end
        end
      end
    end
  end

endmodule
