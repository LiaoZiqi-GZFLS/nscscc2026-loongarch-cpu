// ============================================================================
// la32_decoder.v — LoongArch32r 组合译码器（纯组合，例化×2 于 frontend）
// 编码依据《龙芯架构32位精简版参考手册》基础整数指令编码表。
// 输出位段见 la32_defs.vh（DEC_* 宏，冻结）。
// ============================================================================
`include "la32_defs.vh"

module la32_decoder(
  input  [31:0]        inst,
  input  [31:0]        pc,
  output reg [`DEC_W-1:0] dec
);

  // 立即数拼装
  wire [31:0] imm_si12  = {{20{inst[21]}}, inst[21:10]};          // 符号扩展 si12
  wire [31:0] imm_ui12  = {20'b0, inst[21:10]};                   // 零扩展 ui12
  wire [31:0] imm_ui5   = {27'b0, inst[14:10]};                   // 零扩展 ui5
  wire [31:0] imm_si20l = {inst[24:5], 12'b0};                    // si20 << 12
  wire [31:0] imm_si20  = {12'b0, inst[24:5]};                    // 零扩展 si20（lu12i，ALU 再 <<12）
  wire [31:0] imm_off16 = {{14{inst[25]}}, inst[25:10], 2'b00};   // 分支 offs16 << 2
  // b/bl（LA32R 精简版）: si26 高/低半交换 —— {inst[9:0], inst[25:10]}，符号位 = inst[9]
  // （官方工具链实证：test.s 全部 7782 条 b/bl 吻合；与 LA64 的连续 si26 不同！）
  wire [31:0] imm_off26 = {{4{inst[9]}}, inst[9:0], inst[25:10], 2'b00};
  wire [31:0] imm_si14  = {{16{inst[23]}}, inst[23:10], 2'b00};   // ll/sc si14 << 2
  wire [31:0] imm_csr   = {18'b0, inst[23:10]};                   // CSR 地址（14bit）
  wire [31:0] imm_code  = {17'b0, inst[14:0]};                    // syscall/break code

  reg [31:0] imm;
  reg [5:0]  aluop;
  reg [2:0]  fu;
  reg        rd_wen;
  reg [4:0]  rj, rk, rd;
  reg        serial;
  reg [3:0]  brtype;
  reg [5:0]  excpt;
  reg        use_rj, use_rk;

  always @* begin
    // 默认值
    imm     = 32'b0;
    aluop   = `AOP_NOP;
    fu      = `FU_ALU;
    rd_wen  = 1'b0;
    rj      = inst[9:5];
    rk      = inst[14:10];
    rd      = inst[4:0];
    serial  = 1'b0;
    brtype  = `BR_NONE;
    excpt   = `EXC_NONE;
    use_rj  = 1'b0;
    use_rk  = 1'b0;

    casez (inst[31:26])
      // ---------------- 分支 ----------------
      6'b010011: begin                       // jirl rd, rj, offs16
        fu     = `FU_BR;
        aluop  = `AOP_PCADD;                 // 链接语义: rd <- pc+4（BRU 处理）
        imm    = imm_off16;                  // 目标 = GR[rj] + sext(offs16)<<2
        brtype = `BR_JIRL;
        rd_wen = 1'b1;                       // rd 为链接寄存器
        use_rj = 1'b1;                       // rj 为基址
        // v2.10：jirl 去串行化。BTB+RAS 已完整预测（ret 弹栈/call 压栈/其余 BTB
        // 目标），预测错走 bru_flush+ckpt 常规恢复，与条件分支同路径。
        // serial 版每个 jirl 都要等 ROB 排空（serial 停顿大头），纯属 v1 遗留。
      end
      6'b010100: begin                       // b si26_swap（LA32R：{inst[9:0],inst[25:10]}<<2）
        fu     = `FU_BR;
        imm    = imm_off26;
        brtype = `BR_B;
      end
      6'b010101: begin                       // bl si26_swap（LA32R；链接到 r1）
        fu     = `FU_BR;
        aluop  = `AOP_PCADD;                 // r1 <- pc+4（BRU 处理）
        imm    = imm_off26;
        brtype = `BR_BL;
        rd     = 5'd1;
        rd_wen = 1'b1;
      end
      6'b010110,                            // beq
      6'b010111,                            // bne
      6'b011000,                            // blt
      6'b011001,                            // bge
      6'b011010,                            // bltu
      6'b011011: begin                      // bgeu
        fu     = `FU_BR;
        imm    = imm_off16;
        // LA 条件分支比较 GR[rj] 与 GR[rd]：rk 槽位放 rd 字段
        rk      = inst[4:0];
        use_rj  = 1'b1;
        use_rk  = 1'b1;
        rd_wen  = 1'b0;
        case (inst[31:26])
          6'b010110: brtype = `BR_BEQ;
          6'b010111: brtype = `BR_BNE;
          6'b011000: brtype = `BR_BLT;
          6'b011001: brtype = `BR_BGE;
          6'b011010: brtype = `BR_BLTU;
          default:   brtype = `BR_BGEU;
        endcase
      end

      default: begin
        casez (inst[31:25])
          7'b0001010: begin                  // lu12i.w rd, si20
            aluop  = `AOP_LUI;               // ALU: imm << 12
            imm    = imm_si20;
            rd_wen = 1'b1;
          end
          7'b0001110: begin                  // pcaddu12i rd, si20
            aluop  = `AOP_PCADD;             // ALU: pc + imm（imm 已 <<12）
            imm    = imm_si20l;
            rd_wen = 1'b1;
          end
          default: begin
            casez (inst[31:24])
              8'h20: begin                   // ll.w rd, rj, si14
                fu     = `FU_LSU;
                aluop  = `AOP_LL;
                imm    = imm_si14;
                rd_wen = 1'b1;
                use_rj = 1'b1;
                serial = 1'b1;
              end
              8'h21: begin                   // sc.w rd, rj, si14
                fu     = `FU_LSU;
                aluop  = `AOP_SC;
                imm    = imm_si14;
                use_rj = 1'b1;
                rk     = inst[4:0];          // rd 字段是写数据/状态源
                use_rk = 1'b1;
                rd_wen = 1'b1;               // rd <- 0/1（成功标志）
                serial = 1'b1;
              end
              8'h04: begin                   // csrrd / csrwr / csrxchg
                fu     = `FU_CSR;
                imm    = imm_csr;
                serial = 1'b1;
                rd_wen = 1'b1;
                if (inst[9:5] == 5'd0) begin      // csrrd rd, csr
                  aluop  = `AOP_CSRRD;
                end else if (inst[9:5] == 5'd1) begin // csrwr rd, csr（源为 rd 字段）
                  aluop  = `AOP_CSRWR;
                  rj     = inst[4:0];
                  use_rj = 1'b1;
                end else begin                    // csrxchg rd, rj(mask), csr
                  aluop  = `AOP_CSRXCHG;
                  rk     = inst[9:5];        // rj 字段是 mask 源
                  use_rk = 1'b1;
                  rj     = inst[4:0];        // rd 字段是交换数据源
                  use_rj = 1'b1;
                end
              end
              default: begin
                casez (inst[31:22])
                  // ---------------- SI12 算术/逻辑 ----------------
                  10'b0000001000: begin      // slti
                    aluop = `AOP_SLT;  imm = imm_si12; rd_wen = 1'b1; use_rj = 1'b1;
                  end
                  10'b0000001001: begin      // sltui
                    aluop = `AOP_SLTU; imm = imm_si12; rd_wen = 1'b1; use_rj = 1'b1;
                  end
                  10'b0000001010: begin      // addi.w
                    aluop = `AOP_ADD;  imm = imm_si12; rd_wen = 1'b1; use_rj = 1'b1;
                  end
                  10'b0000001101: begin      // andi（零扩展）
                    aluop = `AOP_AND;  imm = imm_ui12; rd_wen = 1'b1; use_rj = 1'b1;
                  end
                  10'b0000001110: begin      // ori（零扩展）
                    aluop = `AOP_OR;   imm = imm_ui12; rd_wen = 1'b1; use_rj = 1'b1;
                  end
                  10'b0000001111: begin      // xori（零扩展）
                    aluop = `AOP_XOR;  imm = imm_ui12; rd_wen = 1'b1; use_rj = 1'b1;
                  end
                  // ---------------- 访存 si12 ----------------
                  10'b0010100000: begin      // ld.b
                    fu = `FU_LSU; aluop = `AOP_LDB;  imm = imm_si12;
                    rd_wen = 1'b1; use_rj = 1'b1;
                  end
                  10'b0010100001: begin      // ld.h
                    fu = `FU_LSU; aluop = `AOP_LDH;  imm = imm_si12;
                    rd_wen = 1'b1; use_rj = 1'b1;
                  end
                  10'b0010100010: begin      // ld.w
                    fu = `FU_LSU; aluop = `AOP_LDW;  imm = imm_si12;
                    rd_wen = 1'b1; use_rj = 1'b1;
                  end
                  10'b0010100100: begin      // st.b
                    fu = `FU_LSU; aluop = `AOP_STB;  imm = imm_si12;
                    use_rj = 1'b1; rk = inst[4:0]; use_rk = 1'b1;
                  end
                  10'b0010100101: begin      // st.h
                    fu = `FU_LSU; aluop = `AOP_STH;  imm = imm_si12;
                    use_rj = 1'b1; rk = inst[4:0]; use_rk = 1'b1;
                  end
                  10'b0010100110: begin      // st.w
                    fu = `FU_LSU; aluop = `AOP_STW;  imm = imm_si12;
                    use_rj = 1'b1; rk = inst[4:0]; use_rk = 1'b1;
                  end
                  10'b0010101000: begin      // ld.bu
                    fu = `FU_LSU; aluop = `AOP_LDBU; imm = imm_si12;
                    rd_wen = 1'b1; use_rj = 1'b1;
                  end
                  10'b0010101001: begin      // ld.hu
                    fu = `FU_LSU; aluop = `AOP_LDHU; imm = imm_si12;
                    rd_wen = 1'b1; use_rj = 1'b1;
                  end
                  default: begin
                    casez (inst[31:15])
                      // ---------------- 3R ----------------
                      17'b0000000000100000: begin aluop=`AOP_ADD;  rd_wen=1; use_rj=1; use_rk=1; end // add.w
                      17'b0000000000100010: begin aluop=`AOP_SUB;  rd_wen=1; use_rj=1; use_rk=1; end // sub.w
                      17'b0000000000100100: begin aluop=`AOP_SLT;  rd_wen=1; use_rj=1; use_rk=1; end // slt
                      17'b0000000000100101: begin aluop=`AOP_SLTU; rd_wen=1; use_rj=1; use_rk=1; end // sltu
                      17'b0000000000101000: begin aluop=`AOP_NOR;  rd_wen=1; use_rj=1; use_rk=1; end // nor
                      17'b0000000000101001: begin aluop=`AOP_AND;  rd_wen=1; use_rj=1; use_rk=1; end // and
                      17'b0000000000101010: begin aluop=`AOP_OR;   rd_wen=1; use_rj=1; use_rk=1; end // or
                      17'b0000000000101011: begin aluop=`AOP_XOR;  rd_wen=1; use_rj=1; use_rk=1; end // xor
                      17'b0000000000101110: begin aluop=`AOP_SLL;  rd_wen=1; use_rj=1; use_rk=1; end // sll.w
                      17'b0000000000101111: begin aluop=`AOP_SRL;  rd_wen=1; use_rj=1; use_rk=1; end // srl.w
                      17'b0000000000110000: begin aluop=`AOP_SRA;  rd_wen=1; use_rj=1; use_rk=1; end // sra.w
                      17'b0000000000111000: begin fu=`FU_MDU; aluop=`AOP_MUL;  rd_wen=1; use_rj=1; use_rk=1; end // mul.w
                      17'b0000000000111001: begin fu=`FU_MDU; aluop=`AOP_MULH; rd_wen=1; use_rj=1; use_rk=1; end // mulh.w
                      17'b0000000000111010: begin fu=`FU_MDU; aluop=`AOP_MULHU;rd_wen=1; use_rj=1; use_rk=1; end // mulh.wu
                      17'b0000000001000000: begin fu=`FU_MDU; aluop=`AOP_DIV;  rd_wen=1; use_rj=1; use_rk=1; end // div.w
                      17'b0000000001000001: begin fu=`FU_MDU; aluop=`AOP_MOD;  rd_wen=1; use_rj=1; use_rk=1; end // mod.w
                      17'b0000000001000010: begin fu=`FU_MDU; aluop=`AOP_DIVU; rd_wen=1; use_rj=1; use_rk=1; end // div.wu
                      17'b0000000001000011: begin fu=`FU_MDU; aluop=`AOP_MODU; rd_wen=1; use_rj=1; use_rk=1; end // mod.wu
                      // ---------------- UI5 移位 ----------------
                      17'b00000000010000001: begin aluop=`AOP_SLL; imm=imm_ui5; rd_wen=1; use_rj=1; end // slli.w
                      17'b00000000010001001: begin aluop=`AOP_SRL; imm=imm_ui5; rd_wen=1; use_rj=1; end // srli.w
                      17'b00000000010010001: begin aluop=`AOP_SRA; imm=imm_ui5; rd_wen=1; use_rj=1; end // srai.w
                      // ---------------- 系统 ----------------
                      17'b0000000001010100: begin // break code
                        fu=`FU_CSR; aluop=`AOP_BREAK; imm=imm_code; serial=1'b1;
                      end
                      17'b0000000001010110: begin // syscall code
                        fu=`FU_CSR; aluop=`AOP_SYSCALL; imm=imm_code; serial=1'b1;
                      end
                      default: begin
                        if (inst == 32'h06483800) begin // ertn
                          fu=`FU_CSR; aluop=`AOP_ERTN; serial=1'b1;
                        // 修复#9（n58 实证）：LA32R 的 RDCNTVL.W/RDCNTVH.W/RDCNTID
                        // 分别对应 LA64 的 RDTIMEL.W rd,zero / RDTIMEH.W rd,zero /
                        // RDTIMEL.W zero,rj —— rdcntvl.w 与 rdcntid 共享 0x18 编码：
                        //   rj==0            -> rdcntvl.w rd（读 stable counter 低字）
                        //   rj!=0 且 rd==0   -> rdcntid rj（读 TID，目的在 rj 字段）
                        // 此前 0x18 强要 rj==0 把 rdcntid 判成 INE，且误用 0x1a
                        // （RDTIME.D，LA32R 中不存在，应落 INE）
                        end else if (inst[31:10] == 22'h000018 && inst[9:5] == 5'd0) begin
                          fu=`FU_CSR; aluop=`AOP_RDCNTVL; rd_wen=1; serial=1; // rdcntvl.w rd
                        end else if (inst[31:10] == 22'h000018 && inst[4:0] == 5'd0) begin
                          fu=`FU_CSR; aluop=`AOP_RDCNTID; rd_wen=1; serial=1; // rdcntid rj
                          rd = inst[9:5];                 // 目的在 rj 字段
                        end else if (inst[31:10] == 22'h000019 && inst[9:5] == 5'd0) begin
                          fu=`FU_CSR; aluop=`AOP_RDCNTVH; rd_wen=1; serial=1; // rdcntvh.w rd
                        end else begin
                          // 非法指令
                          fu    = `FU_ALU;
                          aluop = `AOP_NOP;
                          excpt = `EXC_INE;
                        end
                      end
                    endcase
                  end
                endcase
              end
            endcase
          end
        endcase
      end
    endcase

    // 取指地址错优先注入 ADEF
    if (pc[1:0] != 2'b00)
      excpt = `EXC_ADEF;
  end

  always @* begin
    dec              = {`DEC_W{1'b0}};
    dec[`DEC_PC]     = pc;
    dec[`DEC_IMM]    = imm;
    dec[`DEC_ALUOP]  = aluop;
    dec[`DEC_FU]     = fu;
    dec[`DEC_RD_WEN] = rd_wen;
    dec[`DEC_RJ]     = rj;
    dec[`DEC_RK]     = rk;
    dec[`DEC_RD]     = rd;
    dec[`DEC_SERIAL] = serial;
    dec[`DEC_BRTYPE] = brtype;
    dec[`DEC_EXCPT]  = excpt;
    dec[`DEC_VALID]  = 1'b1;      // 由 frontend 按 FIFO 占用情况屏蔽
    dec[`DEC_USE_RJ] = use_rj;
    dec[`DEC_USE_RK] = use_rk;
    // v3 BPU 分支类别：cond 查 PHT；bl/jirl(rd!=0) 为 call（RAS 压栈）；
    // jirl r0,r1,0 为 ret（RAS 弹栈给目标）；其余恒 taken
    dec[`DEC_BR_CAT] =
      (brtype == `BR_BL)                          ? `BC_CALL  :
      (brtype == `BR_JIRL)                        ?
        ((rj == 5'd1 && rd == 5'd0) ? `BC_RET   :
         (rd != 5'd0)               ? `BC_CALL  : `BC_UNCOND) :
      (brtype != `BR_NONE && brtype != `BR_B)     ? `BC_COND  : `BC_UNCOND;
  end

endmodule
