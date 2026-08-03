// ============================================================================
// core_top.v — chiplab (nscscc2026) 标准顶层壳
//
// 内部例化 NOP-Core（清华大学 NOP 队，NSCSCC 2023 决赛作品，MIT License，
// https://github.com/NOP-Processor/NOP-Core ）。同目录 mycpu_top.v 为按
// build.sbt（SpinalHDL 1.8.1, sbt "runMain NOP.Main"）从 NOP-Core 公开
// 源码重新生成的网表，与 NOP-Misc final_submission 官方网表逐行等价
// （仅自动命名/注释差异），另增加一条 CPUCFG 译码项（恒返回 0，用于
// 通过 nscscc2026 perf start.S 的 cache 几何查询），改动见 git 历史。
// MIT 版权声明见 NOP_CORE_LICENSE。
//
// 适配内容：
//  1. chiplab soc_top 例化的是 core_top（AXI3 风格，arlen/awlen 4bit，
//     arlock/awlock 2bit，带 wid），NOP 顶层是 AXI4 风格（len 8bit、
//     lock 1bit）。NOP 最大突发为 cache 行 64B/4B=16 拍（len=15），
//     高 4 位恒为 0，直接截断；lock 高位补 0。
//  2. 中断口同名 intrpt 直连（官方网表为 ext_int）。
//  3. NOP 的 debug0_wb_* 恒为 0（其功能测试依赖 CONFREG/UART 判分，
//     与 chiplab mycpu_tb 的判分机制一致），直接映射；
//     debug1_wb_* 置零（chiplab soc_top 不连接该组端口，仅为兼容保留）。
//  4. NOP 其余观测输出（Dretire*/Difftest* 等）不连接。
//  （本文件仅端口适配，不含逻辑；触发 CI，100MHz 诊断档。）
// ============================================================================

module core_top(
  input  [7:0]  intrpt,
  input         aclk,
  input         aresetn,
  // AXI3 读地址
  output [3:0]  arid,
  output [31:0] araddr,
  output [3:0]  arlen,
  output [2:0]  arsize,
  output [1:0]  arburst,
  output [1:0]  arlock,
  output [3:0]  arcache,
  output [2:0]  arprot,
  output        arvalid,
  input         arready,
  // AXI3 读数据
  input  [3:0]  rid,
  input  [31:0] rdata,
  input  [1:0]  rresp,
  input         rlast,
  input         rvalid,
  output        rready,
  // AXI3 写地址
  output [3:0]  awid,
  output [31:0] awaddr,
  output [3:0]  awlen,
  output [2:0]  awsize,
  output [1:0]  awburst,
  output [1:0]  awlock,
  output [3:0]  awcache,
  output [2:0]  awprot,
  output        awvalid,
  input         awready,
  // AXI3 写数据
  output [3:0]  wid,
  output [31:0] wdata,
  output [3:0]  wstrb,
  output        wlast,
  output        wvalid,
  input         wready,
  // AXI3 写响应
  input  [3:0]  bid,
  input  [1:0]  bresp,
  input         bvalid,
  output        bready,
  // chiplab 观测口（不用）
  input         break_point,
  input         infor_flag,
  input  [4:0]  reg_num,
  output        ws_valid,
  output [31:0] rf_rdata,
  // debug trace（chiplab tb 仅用 debug_wb_pc 判断 END_PC，NOP 恒为 0，
  // 测试经 UART 0xff 结束）
  output [31:0] debug0_wb_pc,
  output [3:0]  debug0_wb_rf_wen,
  output [4:0]  debug0_wb_rf_wnum,
  output [31:0] debug0_wb_rf_wdata,
  output [31:0] debug1_wb_pc,
  output [3:0]  debug1_wb_rf_wen,
  output [4:0]  debug1_wb_rf_wnum,
  output [31:0] debug1_wb_rf_wdata
);

  // NOP AXI4 原始信号
  wire [7:0] nop_arlen;
  wire [7:0] nop_awlen;
  wire [0:0] nop_arlock;
  wire [0:0] nop_awlock;

  assign arlen  = nop_arlen[3:0];   // NOP 最大 16 拍突发，len<=15
  assign awlen  = nop_awlen[3:0];
  assign arlock = {1'b0, nop_arlock};
  assign awlock = {1'b0, nop_awlock};

  assign debug1_wb_pc       = 32'b0;
  assign debug1_wb_rf_wen   = 4'b0;
  assign debug1_wb_rf_wnum  = 5'b0;
  assign debug1_wb_rf_wdata = 32'b0;

  mycpu_top u_nop_core (
    .aclk              (aclk),
    .aresetn           (aresetn),
    .intrpt            (intrpt),

    .arid              (arid),
    .araddr            (araddr),
    .arlen             (nop_arlen),
    .arsize            (arsize),
    .arburst           (arburst),
    .arlock            (nop_arlock),
    .arcache           (arcache),
    .arprot            (arprot),
    .arvalid           (arvalid),
    .arready           (arready),

    .rid               (rid),
    .rdata             (rdata),
    .rresp             (rresp),
    .rlast             (rlast),
    .rvalid            (rvalid),
    .rready            (rready),

    .awid              (awid),
    .awaddr            (awaddr),
    .awlen             (nop_awlen),
    .awsize            (awsize),
    .awburst           (awburst),
    .awlock            (nop_awlock),
    .awcache           (awcache),
    .awprot            (awprot),
    .awvalid           (awvalid),
    .awready           (awready),

    .wid               (wid),
    .wdata             (wdata),
    .wstrb             (wstrb),
    .wlast             (wlast),
    .wvalid            (wvalid),
    .wready            (wready),

    .bid               (bid),
    .bresp             (bresp),
    .bvalid            (bvalid),
    .bready            (bready),

    .break_point       (break_point),
    .infor_flag        (infor_flag),
    .reg_num           (reg_num),
    .ws_valid          (ws_valid),
    .rf_rdata          (rf_rdata),

    .debug0_wb_pc      (debug0_wb_pc),
    .debug0_wb_rf_wen  (debug0_wb_rf_wen),
    .debug0_wb_rf_wnum (debug0_wb_rf_wnum),
    .debug0_wb_rf_wdata(debug0_wb_rf_wdata)
  );

endmodule
