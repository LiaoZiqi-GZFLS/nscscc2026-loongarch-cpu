// ============================================================================
// csr_file.v — LA32R-2S CSR + 例外/中断/定时器 + 稳定计数器 + LLbit
// 见 SPEC.md §4.7。纯 Verilog-2001。
//
// CSR 集（LA32r 手册）：
//   CRMD(0x0) PRMD(0x1) EUEN(0x2) ECFG(0x4) ESTAT(0x5) ERA(0x6) BADV(0x7)
//   EENTRY(0xC) CPUID(0x20) SAVE0-3(0x30-0x33) TID(0x40) TCFG(0x41)
//   TVAL(0x42) TICLR(0x44) LLBCTL(0x60)
//
// 手册假设（与实现相关处已在代码注释标出）：
//  - CRMD: PLV[1:0], IE[2]（无 MMU，DA/PG 等位不实现，读 0）
//  - PRMD: PPLV[1:0], PIE[2]
//  - ECFG: LIE[12:0]（bit10 保留恒 0），VS 不实现
//  - ESTAT: IS[1:0] 软中断(csr 可写)，IS[9:2]=intrpt[7:0]（不锁存，实时），
//    IS[10]=0，IS[11]=定时器，IS[12]=0(IPI 不实现)；ECODE[21:16] ESUBCODE[30:22]
//  - EENTRY: VA[31:6] 可写，低 6 位恒 0
//  - TVAL: csr 只读（写忽略）；写 TCFG 时 TVAL<={InitVal,2'b00}
//  - 定时器：en 且 TVAL!=0 每拍减 1；TVAL==0 置 ESTAT.IS[11]，
//    periodic 则重载 {InitVal,2'b00}，否则停在 0；TICLR 写 1 清 IS[11]（不重载）
//  - LLBCTL: bit0 ROLLB=LLbit(只读)，bit2 KLO 写 1 清 LLbit（按任务简化语义，
//    KLO 位自身存储可读回）；bit1 不实现
//  - CPUID 读 0（无队号）；未实现地址读 0、写忽略
//  - 例外入口：ERA/BADV/ESTAT.ECODE/CRMD/PRMD 更新；BADV 仅 ADEF/ALE 更新；
//    exc_code[5]=1（EXCF_IS_INT 内部标记）时 ECODE 转为 INT(0x0)
// ============================================================================
`include "la32_defs.vh"

module csr_file(
  input clk, input rst_n,
  // CSR 指令执行（C4 串行点保证独占，WB 级一拍完成）
  input csr_req,
  input [5:0] csr_aluop,          // AOP_CSRRD/CSRWR/CSRXCHG/RDCNTVL/RDCNTVH/RDCNTID
  input [13:0] csr_addr,
  input [31:0] csr_wdata,         // rd 原值（csrxchg 交换用）
  input [31:0] csr_wmask,         // csrxchg 的 rj mask；csrwr 视为全 1
  output reg [31:0] csr_rdata,    // 组合读
  // 例外入口（ROB 例外序列）
  input exc_active, input [5:0] exc_code, input [31:0] exc_era, input [31:0] exc_badv,
  output [31:0] eentry,
  // ertn
  input ertn_exec, output [31:0] era_out,
  // 中断
  input [7:0] intrpt, output int_pending,
  // LLbit
  input ll_set, input sc_clear, input bru_flush, input exc_flush_ll,
  output ll_bit,
  // 稳定计数器
  output [63:0] stable_cnt
);

  // ---------------- CSR 寄存器 ----------------
  reg [31:0] crmd;        // [1:0]PLV [2]IE
  reg [31:0] prmd;        // [1:0]PPLV [2]PIE
  reg [31:0] euen;        // [0]
  reg [31:0] ecfg;        // [12:0]LIE（bit10 恒 0）
  reg [1:0]  estat_sw;    // ESTAT.IS[1:0] 软中断
  reg        estat_ti;    // ESTAT.IS[11] 定时器中断
  reg [5:0]  estat_ecode; // ESTAT.ECODE[21:16]
  reg [8:0]  estat_esub;  // ESTAT.ESUBCODE[30:22]
  reg [31:0] era;
  reg [31:0] badv;
  reg [31:0] eentry_r;    // [31:6]VA，低 6 位恒 0
  reg [31:0] save0, save1, save2, save3;
  reg [31:0] tid;
  reg [31:0] tcfg;        // [0]EN [1]PERIODIC [31:2]INITVAL
  reg [31:0] tval;
  reg        llbit;
  reg        llbctl_klo;  // LLBCTL.KLO（简化语义：写 1 同时清 LLbit）
  reg [63:0] cnt;         // 稳定计数器

  // ESTAT.IS 全向量（组合）
  wire [12:0] is_vec = {1'b0, estat_ti, 1'b0, intrpt, estat_sw};

  // ---------------- CSR 写解码 ----------------
  wire csr_wr   = csr_req && ((csr_aluop == `AOP_CSRWR) || (csr_aluop == `AOP_CSRXCHG));
  wire [31:0] mw = (csr_aluop == `AOP_CSRXCHG) ? csr_wmask : 32'hffff_ffff;
  // 带掩码更新值（调用方再与可写位掩码相与）
  wire [31:0] wv = csr_wdata & mw;

  // 可写位掩码
  localparam [31:0] M_CRMD   = 32'h0000_0007;   // PLV, IE
  localparam [31:0] M_PRMD   = 32'h0000_0007;   // PPLV, PIE
  localparam [31:0] M_EUEN   = 32'h0000_0001;
  localparam [31:0] M_ECFG   = 32'h0000_1bff;   // LIE[12:11],[9:0]，bit10=0
  localparam [31:0] M_EENTRY = 32'hffff_ffc0;

  wire [31:0] crmd_new   = (crmd   & ~mw) | (wv & M_CRMD);
  wire [31:0] prmd_new   = (prmd   & ~mw) | (wv & M_PRMD);
  wire [31:0] euen_new   = (euen   & ~mw) | (wv & M_EUEN);
  wire [31:0] ecfg_new   = (ecfg   & ~mw) | (wv & M_ECFG);
  wire [31:0] eentry_new = (eentry_r & ~mw) | (wv & M_EENTRY);
  wire [31:0] tcfg_new   = (tcfg   & ~mw) |  wv;

  // ---------------- 组合读 ----------------
  always @(*) begin
    case (csr_aluop)
      `AOP_RDCNTVL: csr_rdata = cnt[31:0];
      `AOP_RDCNTVH: csr_rdata = cnt[63:32];
      `AOP_RDCNTID: csr_rdata = tid;
      // cpucfg：恒返回 0 —— 上报无 I/D/L2 cache，perf start.S 据此跳过全部
      // cacop cache 初始化循环；其余配置字（PRID 等）本设计不使用，读 0 安全。
      `AOP_CPUCFG:  csr_rdata = 32'b0;
      default: begin
        case (csr_addr)
          `CSR_CRMD:   csr_rdata = crmd;
          `CSR_PRMD:   csr_rdata = prmd;
          `CSR_EUEN:   csr_rdata = euen;
          `CSR_ECFG:   csr_rdata = ecfg;
          `CSR_ESTAT:  csr_rdata = {1'b0, estat_esub, estat_ecode, 3'b000, is_vec};
          `CSR_ERA:    csr_rdata = era;
          `CSR_BADV:   csr_rdata = badv;
          `CSR_EENTRY: csr_rdata = eentry_r;
          `CSR_CPUID:  csr_rdata = 32'b0;
          `CSR_SAVE0:  csr_rdata = save0;
          `CSR_SAVE1:  csr_rdata = save1;
          `CSR_SAVE2:  csr_rdata = save2;
          `CSR_SAVE3:  csr_rdata = save3;
          `CSR_TID:    csr_rdata = tid;
          `CSR_TCFG:   csr_rdata = tcfg;
          `CSR_TVAL:   csr_rdata = tval;
          `CSR_TICLR:  csr_rdata = 32'b0;             // 写专用，读 0
          `CSR_LLBCTL: csr_rdata = {29'b0, llbctl_klo, 1'b0, llbit};
          default:     csr_rdata = 32'b0;             // 未实现地址读 0
        endcase
      end
    endcase
  end

  // ---------------- 时序 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      crmd        <= 32'b0;               // PLV=0, IE=0
      prmd        <= 32'b0;
      euen        <= 32'b0;
      ecfg        <= 32'b0;               // LIE=0
      estat_sw    <= 2'b0;
      estat_ti    <= 1'b0;
      estat_ecode <= 6'b0;
      estat_esub  <= 9'b0;
      era         <= 32'b0;
      badv        <= 32'b0;
      eentry_r    <= 32'b0;
      save0       <= 32'b0;
      save1       <= 32'b0;
      save2       <= 32'b0;
      save3       <= 32'b0;
      tid         <= 32'b0;
      tcfg        <= 32'b0;
      tval        <= 32'b0;
      llbit       <= 1'b0;
      llbctl_klo  <= 1'b0;
      cnt         <= 64'b0;
    end else begin
      // ---- 稳定计数器：复位起每拍 +1 ----
      cnt <= cnt + 64'd1;

      // ---- 定时器 ----
      if (tcfg[0]) begin
        if (tval == 32'b0) begin
          estat_ti <= 1'b1;
          if (tcfg[1]) begin
            tval <= {tcfg[31:2], 2'b00};   // periodic 重载
          end else begin
            tcfg[0] <= 1'b0;               // 非周期到 0：硬件清 EN，停止（不再重复置 IS[11]）
          end
        end else begin
          tval <= tval - 32'd1;
        end
      end

      // ---- LLbit：置 1 / 清 0（清优先级高） ----
      if (ll_set) llbit <= 1'b1;
      if (sc_clear || bru_flush || exc_flush_ll) llbit <= 1'b0;

      // ---- CSR 指令写 ----
      if (csr_wr) begin
        case (csr_addr)
          `CSR_CRMD:   crmd   <= crmd_new;
          `CSR_PRMD:   prmd   <= prmd_new;
          `CSR_EUEN:   euen   <= euen_new;
          `CSR_ECFG:   ecfg   <= ecfg_new;
          `CSR_ESTAT:  estat_sw <= (estat_sw & ~mw[1:0]) | (wv[1:0]); // 仅 IS[1:0] 可写
          `CSR_ERA:    era    <= (era & ~mw) | wv;
          `CSR_BADV:   badv   <= (badv & ~mw) | wv;
          `CSR_EENTRY: eentry_r <= eentry_new;
          `CSR_SAVE0:  save0  <= (save0 & ~mw) | wv;
          `CSR_SAVE1:  save1  <= (save1 & ~mw) | wv;
          `CSR_SAVE2:  save2  <= (save2 & ~mw) | wv;
          `CSR_SAVE3:  save3  <= (save3 & ~mw) | wv;
          `CSR_TID:    tid    <= (tid & ~mw) | wv;
          `CSR_TCFG: begin
             tcfg <= tcfg_new;
             tval <= {tcfg_new[31:2], 2'b00};   // 写 TCFG 初始化 TVAL
          end
          `CSR_TVAL:   ;                          // 只读，写忽略
          `CSR_TICLR:  if (wv[0]) estat_ti <= 1'b0; // 写 1 清定时器中断
          `CSR_LLBCTL: begin
             llbctl_klo <= (llbctl_klo & ~mw[2]) | wv[2];
             if (wv[2]) llbit <= 1'b0;             // KLO 写 1 清 LLB（简化语义）
          end
          default: ;                              // 未实现地址写忽略
        endcase
      end

      // ---- 例外入口（优先级高于 CSR 写；C4 串行化保证不冲突） ----
      if (exc_active) begin
        era <= exc_era;
        if ((exc_code == `EXC_ADEF) || (exc_code == `EXC_ALE))
          badv <= exc_badv;
        estat_ecode <= exc_code[5] ? 6'h00 : exc_code;  // EXCF_IS_INT -> INT
        estat_esub  <= 9'b0;
        crmd[2]   <= 1'b0;            // IE <- 0
        crmd[1:0] <= 2'b0;            // PLV <- 0
        prmd[1:0] <= crmd[1:0];       // PPLV <- 旧 PLV
        prmd[2]   <= crmd[2];         // PIE  <- 旧 IE
        llbit     <= 1'b0;            // 例外清 LLbit
      end

      // ---- ertn ----
      if (ertn_exec) begin
        crmd[1:0] <= prmd[1:0];       // PLV <- PPLV
        crmd[2]   <= prmd[2];         // IE  <- PIE
        llbit     <= 1'b0;            // ertn 清 LLbit
      end
    end
  end

  // ---------------- 输出 ----------------
  assign eentry      = eentry_r;
  assign era_out     = era;
  assign ll_bit      = llbit;
  assign stable_cnt  = cnt;
  assign int_pending = (|(is_vec & ecfg[12:0])) & crmd[2];

endmodule
