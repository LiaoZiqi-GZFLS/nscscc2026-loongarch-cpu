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
    .arid               (arid),
    .araddr             (araddr),
    .arlen              (arlen),
    .arsize             (arsize),
    .arburst            (arburst),
    .arlock             (arlock),
    .arcache            (arcache),
    .arprot             (arprot),
    .arvalid            (arvalid),
    .arready            (arready),
    .rid                (rid),
    .rdata              (rdata),
    .rresp              (rresp),
    .rlast              (rlast),
    .rvalid             (rvalid),
    .rready             (rready),
    .awid               (awid),
    .awaddr             (awaddr),
    .awlen              (awlen),
    .awsize             (awsize),
    .awburst            (awburst),
    .awlock             (awlock),
    .awcache            (awcache),
    .awprot             (awprot),
    .awvalid            (awvalid),
    .awready            (awready),
    .wid                (wid),
    .wdata              (wdata),
    .wstrb              (wstrb),
    .wlast              (wlast),
    .wvalid             (wvalid),
    .wready             (wready),
    .bid                (bid),
    .bresp              (bresp),
    .bvalid             (bvalid),
    .bready             (bready),
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

endmodule
