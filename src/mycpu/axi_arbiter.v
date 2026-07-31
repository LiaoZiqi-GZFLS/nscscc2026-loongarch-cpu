// ============================================================================
// axi_arbiter.v — IF/LSU 二客户端 AXI3 仲裁
// - 读通道：单 outstanding，LSU 优先；arid 0=IF 1=LSU；按 arid 路由 R 回客户端
// - 写通道：仅 LSU，AW/W 可并行推进（各单 outstanding），B 透传一拍
// - 固定：len=0, size=010(4B), burst=01(INCR), lock/cache/prot=0
// ============================================================================

/* verilator lint_off UNUSEDSIGNAL */
// 说明：rid/rresp/rlast/bid/bresp 为契约端口；len=0 单拍传输下不使用（无错误处理、无需末拍判别）
module axi_arbiter(
  input              clk,
  input              rst_n,
  // IF 客户端
  input              if_arvalid,
  output             if_arready,
  input  [31:0]      if_araddr,
  output reg         if_rvalid,
  output reg [31:0]  if_rdata,
  output reg         if_rlast,
  // LSU 客户端
  input              ls_arvalid,
  output             ls_arready,
  input  [31:0]      ls_araddr,
  input  [3:0]       ls_arlen,   // DCache：miss refill=3 / uncached 单拍=0
  input  [3:0]       if_arlen,   // ICache：需求双行=7 / 预取与 uc=3
  output reg         ls_rvalid,
  output reg [31:0]  ls_rdata,
  output reg         ls_rlast,   // DCache refill burst 末拍判别（LSU 直连时无用）
  input              ls_awvalid,
  output             ls_awready,
  input  [31:0]      ls_awaddr,
  input              ls_wvalid,
  output             ls_wready,
  input  [31:0]      ls_wdata,
  input  [3:0]       ls_wstrb,
  output reg         ls_bvalid,
  // AXI3 master：读地址
  output reg [3:0]   arid,
  output reg [31:0]  araddr,
  output [3:0]       arlen,
  output [2:0]       arsize,
  output [1:0]       arburst,
  output [1:0]       arlock,
  output [3:0]       arcache,
  output [2:0]       arprot,
  output reg         arvalid,
  input              arready,
  // AXI3 master：读数据
  input  [3:0]       rid,
  input  [31:0]      rdata,
  input  [1:0]       rresp,
  input              rlast,
  input              rvalid,
  output reg         rready,
  // AXI3 master：写地址
  output [3:0]       awid,
  output reg [31:0]  awaddr,
  output [3:0]       awlen,
  output [2:0]       awsize,
  output [1:0]       awburst,
  output [1:0]       awlock,
  output [3:0]       awcache,
  output [2:0]       awprot,
  output reg         awvalid,
  input              awready,
  // AXI3 master：写数据
  output [3:0]       wid,
  output reg [31:0]  wdata,
  output reg [3:0]   wstrb,
  output             wlast,
  output reg         wvalid,
  input              wready,
  // AXI3 master：写响应
  input  [3:0]       bid,
  input  [1:0]       bresp,
  input              bvalid,
  output reg         bready
);

  // ================= 读通道 =================
  reg rd_busy;   // 有未完成读
  reg rd_id;     // 0=IF 1=LSU

  // 仲裁：LSU 优先（组合透传地址）
  always @* begin
    if (ls_arvalid) begin
      arid   = 4'd1;
      araddr = ls_araddr;
    end else begin
      arid   = 4'd0;
      araddr = if_araddr;
    end
    arvalid = !rd_busy && (ls_arvalid || if_arvalid);
  end

  assign ls_arready = !rd_busy && arready;                 // LSU 优先，无需看 IF
  assign if_arready = !rd_busy && !ls_arvalid && arready;

  // R 路由（单拍，len=0）
  always @* begin
    rready    = rd_busy;
    if_rvalid = rd_busy && !rd_id && rvalid;
    if_rdata  = rdata;
    if_rlast  = rlast;
    ls_rvalid = rd_busy &&  rd_id && rvalid;
    ls_rdata  = rdata;
    ls_rlast  = rlast;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_busy <= 1'b0;
      rd_id   <= 1'b0;
    end else begin
      if (arvalid && arready) begin
        rd_busy <= 1'b1;
        rd_id   <= ls_arvalid;
      end else if (rvalid && rready && rlast) begin  // burst：末拍才释放
        rd_busy <= 1'b0;
      end
    end
  end

  // ================= 写通道（仅 LSU，AW/W 并行、各单 outstanding） =================
  reg aw_pend;   // AW 已握手、等 B
  reg w_pend;    // W 已握手、等 B

  always @* begin
    awvalid = ls_awvalid && !aw_pend;
    awaddr  = ls_awaddr;
    wvalid  = ls_wvalid && !w_pend;
    wdata   = ls_wdata;
    wstrb   = ls_wstrb;
    bready  = aw_pend && w_pend;
  end

  assign ls_awready = awready && !aw_pend;
  assign ls_wready  = wready  && !w_pend;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_pend   <= 1'b0;
      w_pend    <= 1'b0;
      ls_bvalid <= 1'b0;
    end else begin
      if (awvalid && awready)
        aw_pend <= 1'b1;
      if (wvalid && wready)
        w_pend  <= 1'b1;
      if (bvalid && bready) begin
        aw_pend   <= 1'b0;
        w_pend    <= 1'b0;
        ls_bvalid <= 1'b1;    // B 透传一拍
      end else begin
        ls_bvalid <= 1'b0;
      end
    end
  end

  // ================= 固定参数 =================
  // IF 固定 16B 块取指（arlen=3，一次 4 条）；LSU 由 DCache 决定
  //（cached miss refill=3 组行 / uncached MMIO=0 单拍，防多读副作用）
  assign arlen   = ls_arvalid ? ls_arlen : if_arlen;
  assign arsize  = 3'b010;
  assign arburst = 2'b01;
  assign arlock  = 2'b00;
  assign arcache = 4'd0;
  assign arprot  = 3'd0;

  assign awid    = 4'd1;
  assign awlen   = 4'd0;
  assign awsize  = 3'b010;
  assign awburst = 2'b01;
  assign awlock  = 2'b00;
  assign awcache = 4'd0;
  assign awprot  = 3'd0;

  assign wid     = 4'd1;
  assign wlast   = wvalid;

endmodule
/* verilator lint_on UNUSEDSIGNAL */
