// ============================================================================
// core_top.v — chiplab 标准顶层壳
// 端口与 chiplab soc_top.v 的 core_top 例化完全一致。
// 内部例化 cpu_core（主 agent 负责），AXI/debug 直连；观测口不用，置零。
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
  // debug trace（提交比对）
  output [31:0] debug0_wb_pc,
  output [3:0]  debug0_wb_rf_wen,
  output [4:0]  debug0_wb_rf_wnum,
  output [31:0] debug0_wb_rf_wdata,
  output [31:0] debug1_wb_pc,
  output [3:0]  debug1_wb_rf_wen,
  output [4:0]  debug1_wb_rf_wnum,
  output [31:0] debug1_wb_rf_wdata
);

  cpu_core u_cpu_core(
    .clk                (aclk),
    .rst_n              (aresetn),
    .intrpt             (intrpt),
    .arid               (c_arid),
    .araddr             (c_araddr),
    .arlen              (c_arlen),
    .arsize             (c_arsize),
    .arburst            (c_arburst),
    .arlock             (c_arlock),
    .arcache            (c_arcache),
    .arprot             (c_arprot),
    .arvalid            (c_arvalid),
    .arready            (c_arready),
    .rid                (c_rid),
    .rdata              (c_rdata),
    .rresp              (c_rresp),
    .rlast              (c_rlast),
    .rvalid             (c_rvalid),
    .rready             (c_rready),
    .awid               (c_awid),
    .awaddr             (c_awaddr),
    .awlen              (c_awlen),
    .awsize             (c_awsize),
    .awburst            (c_awburst),
    .awlock             (c_awlock),
    .awcache            (c_awcache),
    .awprot             (c_awprot),
    .awvalid            (c_awvalid),
    .awready            (c_awready),
    .wid                (c_wid),
    .wdata              (c_wdata),
    .wstrb              (c_wstrb),
    .wlast              (c_wlast),
    .wvalid             (c_wvalid),
    .wready             (c_wready),
    .bid                (c_bid),
    .bresp              (c_bresp),
    .bvalid             (c_bvalid),
    .bready             (c_bready),
    .debug0_wb_pc       (debug0_wb_pc),
    .debug0_wb_rf_wen   (debug0_wb_rf_wen),
    .debug0_wb_rf_wnum  (debug0_wb_rf_wnum),
    .debug0_wb_rf_wdata (debug0_wb_rf_wdata),
    .debug1_wb_pc       (debug1_wb_pc),
    .debug1_wb_rf_wen   (debug1_wb_rf_wen),
    .debug1_wb_rf_wnum  (debug1_wb_rf_wnum),
    .debug1_wb_rf_wdata (debug1_wb_rf_wdata)
  );

  // 观测口不用
  assign ws_valid = 1'b0;
  assign rf_rdata = 32'b0;

  // 未用输入防 lint（工具相关，无功能影响）
  wire unused = &{1'b0, break_point, infor_flag, reg_num};

  // ==================== 诊断信标（仅诊断轮，评分前移除） ====================
  // cpu_core 的 AXI3 经 diag_beacon 中转：平时直通；复位后 FIRE_CNT 拍若
  // 程序从未写 NUM_ADDR（func/健康 perf 会写，天然抑制），则夺取总线向
  // confreg 写 NUM/LED_RG0 上报 hang 分类与最后地址/PC（板上唯一可读通道）。
  wire [3:0]  c_arid;
  wire [31:0] c_araddr;
  wire [3:0]  c_arlen;
  wire [2:0]  c_arsize;
  wire [1:0]  c_arburst;
  wire [1:0]  c_arlock;
  wire [3:0]  c_arcache;
  wire [2:0]  c_arprot;
  wire        c_arvalid;
  wire        c_arready;
  wire [3:0]  c_rid;
  wire [31:0] c_rdata;
  wire [1:0]  c_rresp;
  wire        c_rlast;
  wire        c_rvalid;
  wire        c_rready;
  wire [3:0]  c_awid;
  wire [31:0] c_awaddr;
  wire [3:0]  c_awlen;
  wire [2:0]  c_awsize;
  wire [1:0]  c_awburst;
  wire [1:0]  c_awlock;
  wire [3:0]  c_awcache;
  wire [2:0]  c_awprot;
  wire        c_awvalid;
  wire        c_awready;
  wire [3:0]  c_wid;
  wire [31:0] c_wdata;
  wire [3:0]  c_wstrb;
  wire        c_wlast;
  wire        c_wvalid;
  wire        c_wready;
  wire [3:0]  c_bid;
  wire [1:0]  c_bresp;
  wire        c_bvalid;
  wire        c_bready;

  wire cmt_pulse = |debug0_wb_rf_wen | |debug1_wb_rf_wen;
  wire [31:0] cmt_pc = (|debug0_wb_rf_wen) ? debug0_wb_pc : debug1_wb_pc;

  diag_beacon u_diag_beacon(
    .clk       (aclk),
    .rst_n     (aresetn),
    .cmt_pulse (cmt_pulse),
    .cmt_pc    (cmt_pc),

    .c_arid    (c_arid),    .e_arid    (arid),
    .c_araddr  (c_araddr),  .e_araddr  (araddr),
    .c_arlen   (c_arlen),   .e_arlen   (arlen),
    .c_arsize  (c_arsize),  .e_arsize  (arsize),
    .c_arburst (c_arburst), .e_arburst (arburst),
    .c_arlock  (c_arlock),  .e_arlock  (arlock),
    .c_arcache (c_arcache), .e_arcache (arcache),
    .c_arprot  (c_arprot),  .e_arprot  (arprot),
    .c_arvalid (c_arvalid), .e_arvalid (arvalid),
    .c_arready (c_arready), .e_arready (arready),
    .c_rid     (c_rid),     .e_rid     (rid),
    .c_rdata   (c_rdata),   .e_rdata   (rdata),
    .c_rresp   (c_rresp),   .e_rresp   (rresp),
    .c_rlast   (c_rlast),   .e_rlast   (rlast),
    .c_rvalid  (c_rvalid),  .e_rvalid  (rvalid),
    .c_rready  (c_rready),  .e_rready  (rready),
    .c_awid    (c_awid),    .e_awid    (awid),
    .c_awaddr  (c_awaddr),  .e_awaddr  (awaddr),
    .c_awlen   (c_awlen),   .e_awlen   (awlen),
    .c_awsize  (c_awsize),  .e_awsize  (awsize),
    .c_awburst (c_awburst), .e_awburst (awburst),
    .c_awlock  (c_awlock),  .e_awlock  (awlock),
    .c_awcache (c_awcache), .e_awcache (awcache),
    .c_awprot  (c_awprot),  .e_awprot  (awprot),
    .c_awvalid (c_awvalid), .e_awvalid (awvalid),
    .c_awready (c_awready), .e_awready (awready),
    .c_wid     (c_wid),     .e_wid     (wid),
    .c_wdata   (c_wdata),   .e_wdata   (wdata),
    .c_wstrb   (c_wstrb),   .e_wstrb   (wstrb),
    .c_wlast   (c_wlast),   .e_wlast   (wlast),
    .c_wvalid  (c_wvalid),  .e_wvalid  (wvalid),
    .c_wready  (c_wready),  .e_wready  (wready),
    .c_bid     (c_bid),     .e_bid     (bid),
    .c_bresp   (c_bresp),   .e_bresp   (bresp),
    .c_bvalid  (c_bvalid),  .e_bvalid  (bvalid),
    .c_bready  (c_bready),  .e_bready  (bready)
  );

endmodule
