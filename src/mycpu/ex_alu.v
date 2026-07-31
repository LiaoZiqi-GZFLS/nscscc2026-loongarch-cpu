// ============================================================================
// ex_alu.v — 组合 ALU + 分支解析（SPEC §4.6）
// 例化 2 份（lane0/lane1 同构），lane0 的实例接分支解析口。
//   FU_ALU: ADD/SUB/SLT/SLTU/AND/OR/NOR/XOR/SLL/SRL/SRA/LUI/PASSJ/PASSK/PCADD
//   FU_BR : BEQ/BNE/BLT/BGE/BLTU/BGEU 用 src_j 与 src_k 比较（译码已把 rj/rd
//           放入 j/k）；B/BL/JIRL 恒 taken；JIRL 目标 = src_j+imm，其余 pc+imm。
//           分支类 result 固定输出 pc+4（BL/JIRL 链接值）。
//   其他 FU: br_taken=0；result 默认 src_j+imm（亦可用作 LSU 地址计算）。
// ============================================================================
`include "la32_defs.vh"

module ex_alu(
  input [`UOP_W-1:0] uop,
  input [31:0] src_j, input [31:0] src_k,
  output reg [31:0] result,
  output reg br_taken, output reg [31:0] br_target
);

  wire [5:0]  aluop = uop[`UOP_ALUOP];
  wire [2:0]  fu    = uop[`UOP_FU];
  wire [31:0] pc    = uop[`UOP_PC];
  wire [31:0] imm   = uop[`UOP_IMM];
  wire [3:0]  brt   = uop[`UOP_BR_TYPE];

  wire signed [31:0] sj = src_j;
  wire signed [31:0] sk = src_k;

  // ---------------- ALU 数据通路 ----------------
  reg [31:0] alu_result;
  always @(*) begin
    case (aluop)
      `AOP_ADD:   alu_result = src_j + src_k;
      `AOP_SUB:   alu_result = src_j - src_k;
      `AOP_SLT:   alu_result = {31'd0, sj < sk};
      `AOP_SLTU:  alu_result = {31'd0, src_j < src_k};
      `AOP_AND:   alu_result = src_j & src_k;
      `AOP_OR:    alu_result = src_j | src_k;
      `AOP_NOR:   alu_result = ~(src_j | src_k);
      `AOP_XOR:   alu_result = src_j ^ src_k;
      `AOP_SLL:   alu_result = src_j << src_k[4:0];
      `AOP_SRL:   alu_result = src_j >> src_k[4:0];
      `AOP_SRA:   alu_result = sj >>> src_k[4:0];
      `AOP_LUI:   alu_result = imm << 12;
      `AOP_PASSJ: alu_result = src_j;
      `AOP_PASSK: alu_result = src_k;
      `AOP_PCADD: alu_result = pc + imm;
      default:    alu_result = src_j + imm;  // 默认：地址/旁通计算
    endcase
  end

  // 分支类 result 固定为 pc+4（BL/JIRL 链接值）；其余 FU 取 ALU 结果
  always @(*) begin
    result = (fu == `FU_BR) ? (pc + 32'd4) : alu_result;
  end

  // ---------------- 分支解析（组合） ----------------
  reg br_cond;
  always @(*) begin
    case (brt)
      `BR_BEQ:  br_cond = (src_j == src_k);
      `BR_BNE:  br_cond = (src_j != src_k);
      `BR_BLT:  br_cond = (sj < sk);
      `BR_BGE:  br_cond = (sj >= sk);
      `BR_BLTU: br_cond = (src_j < src_k);
      `BR_BGEU: br_cond = (src_j >= src_k);
      `BR_B, `BR_BL, `BR_JIRL: br_cond = 1'b1;
      default:  br_cond = 1'b0;
    endcase
  end

  always @(*) begin
    br_taken  = (fu == `FU_BR) && (brt != `BR_NONE) && br_cond;
    br_target = (brt == `BR_JIRL) ? (src_j + imm) : (pc + imm);
  end

endmodule
