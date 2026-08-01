// ============================================================================
// prf.v — 物理寄存器堆 64x32，4 读 2 写
//   组合读 + 同拍写读直通（SPEC F3）；ready_vec 组合输出。
//   物理 0 号恒 0 且恒 ready（写 0 号被忽略）。
//   写冲突（we0/we1 同地址）时 we0 优先；ready 同拍 set/clr 冲突时 clr 优先。
//   无复位端口（按 SPEC 接口）：ready_r 用 initial 初始化为全 ready，
//   复位态 32..63 在 freelist 中，一经分配即由 rename 拉低对应 ready 位。
// ============================================================================
`include "la32_defs.vh"

module prf(
  input        clk,
  input        rst_n,
  // 4 读（lane0: ra0/rb0, lane1: ra1/rb1）
  input  [5:0] ra0,
  input  [5:0] rb0,
  input  [5:0] ra1,
  input  [5:0] rb1,
  output [31:0] rd0a,
  output [31:0] rd0b,
  output [31:0] rd1a,
  output [31:0] rd1b,
  // 2 写
  input        we0,
  input  [5:0] wa0,
  input  [31:0] wd0,
  input        we1,
  input  [5:0] wa1,
  input  [31:0] wd1,
  // ready 置位（4 个写回完成源）
  input        set_rdy0,
  input  [5:0] rdy_addr0,
  input        set_rdy1,
  input  [5:0] rdy_addr1,
  input        set_rdy2,
  input  [5:0] rdy_addr2,
  input        set_rdy3,
  input  [5:0] rdy_addr3,
  // ready 清零（rename 分配新物理号）
  input        clr_rdy0,
  input  [5:0] clr_addr0,
  input        clr_rdy1,
  input  [5:0] clr_addr1,
  output [63:0] ready_vec
);

  reg [31:0] mem [0:63];
  /* verilator lint_off UNUSEDSIGNAL */  // ready_r[0] 不用：ready_vec[0] 恒 1
  reg [63:0] ready_r;
  /* verilator lint_on UNUSEDSIGNAL */

  integer i;
  initial begin
    ready_r = 64'hffff_ffff_ffff_ffff;
    for (i = 0; i < 64; i = i + 1) mem[i] = 32'b0;
  end

  // 组合读 + 同拍写读直通（写冲突 we0 优先）+ 0 号恒 0
  assign rd0a = (ra0 == 6'd0)             ? 32'b0 :
                (we0 && (wa0 == ra0))     ? wd0   :
                (we1 && (wa1 == ra0))     ? wd1   : mem[ra0];
  assign rd0b = (rb0 == 6'd0)             ? 32'b0 :
                (we0 && (wa0 == rb0))     ? wd0   :
                (we1 && (wa1 == rb0))     ? wd1   : mem[rb0];
  assign rd1a = (ra1 == 6'd0)             ? 32'b0 :
                (we0 && (wa0 == ra1))     ? wd0   :
                (we1 && (wa1 == ra1))     ? wd1   : mem[ra1];
  assign rd1b = (rb1 == 6'd0)             ? 32'b0 :
                (we0 && (wa0 == rb1))     ? wd0   :
                (we1 && (wa1 == rb1))     ? wd1   : mem[rb1];

  // 写口（忽略写 0 号）
  always @(posedge clk) begin
    if (we0 && (wa0 != 6'd0)) mem[wa0] <= wd0;
    if (we1 && (wa1 != 6'd0)) mem[wa1] <= wd1;
  end

  // ready 位：clr 优先于 set（同一物理号在被重命名复用前不可能有在途写回，
  // 此处为防御性约定）
  // 【板上复位修复】ready_r 必须随 rst_n 回全 1：FPGA 的 initial 只在配置后
  // 生效一次。板级启动流程是"上电自由跑 → JTAG 复位 → 重启"，复位瞬间若有
  // 在途写回（ready_r[x]=0），复位后 rename 初始映射 arch i→phys i（0-31）
  // 会继承 ready=0 的物理号 → 读该 arch 寄存器的指令永远等不到 ready →
  // issue 死锁 → 板上 num_data 恒 0（本地单复位仿真永不复现）。
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      ready_r <= 64'hffff_ffff_ffff_ffff;
    else begin
      if (set_rdy0) ready_r[rdy_addr0] <= 1'b1;
      if (set_rdy1) ready_r[rdy_addr1] <= 1'b1;
      if (set_rdy2) ready_r[rdy_addr2] <= 1'b1;
      if (set_rdy3) ready_r[rdy_addr3] <= 1'b1;
      if (clr_rdy0) ready_r[clr_addr0] <= 1'b0;
      if (clr_rdy1) ready_r[clr_addr1] <= 1'b0;
    end
  end

  assign ready_vec = {ready_r[63:1], 1'b1};   // 0 号恒 ready

endmodule
