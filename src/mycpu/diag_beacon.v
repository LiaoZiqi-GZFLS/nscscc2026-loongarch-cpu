// ============================================================================
// diag_beacon.v — 板上 perf 全灭诊断信标（仅诊断轮使用，评分前必须移除！）
//
// 背景：同一 RTL + 同一 allbench 二进制，本地 Verilator perf 仿真 Test Success，
// 板上 func 58/58×3 通过，但板上 perf 40/40 run 全部 TIMEOUT、correct_flag=0。
// 板上唯一可读通道 = vio.tcl 轮询的 led_rg0（correct_flag）与其后读取的
// num_data（soc_count/cpu_count 字段）。
//
// 机制：复位释放后计数 FIRE_CNT 个 cpu_clk（200M：25MHz 下 8s，30s 超时内）。
// 若届时程序从未写 NUM_ADDR（func 与"健康的 perf"都会写，天然抑制），
// 则夺取 AXI3 主口，向 confreg 发两笔单拍写：
//   NUM_ADDR     <- payload（分类信息）
//   LED_RG0_ADDR <- code   （非 0 → tcl 立即记录并读取 num）
// code: 01=无任何提交（启动即卡死） 10=有提交但没写过 confreg（早期崩溃，
//       如 INE 掉进 0x380 死循环） 11=写过 confreg（深度启动完成，死于
//       UART/分发/benchmark）
// payload: code==10 → 最后提交 PC；否则 → 最后发出的 AXI 地址
//         （若卡死在 UART 读，outstanding 地址即 0xbfe001e0，直接实锤）
//
// 夺取期间：CPU 侧全部 ready 拉 0（停住），外部 rready/bready=1 吸收
// 滞留响应（被卡的 outstanding 事务的晚归 R/B 直接丢弃）。夺取不释放。
// ============================================================================

module diag_beacon #(
  parameter [31:0] FIRE_CNT = 32'd200_000_000
)(
  input         clk,
  input         rst_n,

  // 提交观测（来自 debug trace 口：commit 级 wen/pc，板上 trace 比对已验证其忠实性）
  input         cmt_pulse,
  input  [31:0] cmt_pc,

  // CPU 侧 AXI3（接 cpu_core 输出）
  input  [3:0]  c_arid,
  input  [31:0] c_araddr,
  input  [3:0]  c_arlen,
  input  [2:0]  c_arsize,
  input  [1:0]  c_arburst,
  input  [1:0]  c_arlock,
  input  [3:0]  c_arcache,
  input  [2:0]  c_arprot,
  input         c_arvalid,
  output        c_arready,
  output [3:0]  c_rid,
  output [31:0] c_rdata,
  output [1:0]  c_rresp,
  output        c_rlast,
  output        c_rvalid,
  input         c_rready,
  input  [3:0]  c_awid,
  input  [31:0] c_awaddr,
  input  [3:0]  c_awlen,
  input  [2:0]  c_awsize,
  input  [1:0]  c_awburst,
  input  [1:0]  c_awlock,
  input  [3:0]  c_awcache,
  input  [2:0]  c_awprot,
  input         c_awvalid,
  output        c_awready,
  input  [3:0]  c_wid,
  input  [31:0] c_wdata,
  input  [3:0]  c_wstrb,
  input         c_wlast,
  input         c_wvalid,
  output        c_wready,
  output [3:0]  c_bid,
  output [1:0]  c_bresp,
  output        c_bvalid,
  input         c_bready,

  // 外部 AXI3（接 core_top 端口 → soc）
  output [3:0]  e_arid,
  output [31:0] e_araddr,
  output [3:0]  e_arlen,
  output [2:0]  e_arsize,
  output [1:0]  e_arburst,
  output [1:0]  e_arlock,
  output [3:0]  e_arcache,
  output [2:0]  e_arprot,
  output        e_arvalid,
  input         e_arready,
  input  [3:0]  e_rid,
  input  [31:0] e_rdata,
  input  [1:0]  e_rresp,
  input         e_rlast,
  input         e_rvalid,
  output        e_rready,
  output [3:0]  e_awid,
  output [31:0] e_awaddr,
  output [3:0]  e_awlen,
  output [2:0]  e_awsize,
  output [1:0]  e_awburst,
  output [1:0]  e_awlock,
  output [3:0]  e_awcache,
  output [2:0]  e_awprot,
  output        e_awvalid,
  input         e_awready,
  output [3:0]  e_wid,
  output [31:0] e_wdata,
  output [3:0]  e_wstrb,
  output        e_wlast,
  output        e_wvalid,
  input         e_wready,
  input  [3:0]  e_bid,
  input  [1:0]  e_bresp,
  input         e_bvalid,
  output        e_bready
);

  localparam [31:0] NUM_ADDR     = 32'hbfaf_f050;
  localparam [31:0] LED_RG0_ADDR = 32'hbfaf_f030;

  // ---------------- 遥测 ----------------
  reg [31:0] cnt;
  reg        commit_seen, confwr_seen, num_seen;
  reg [31:0] last_cmt_pc, last_axi_addr;

  wire c_ar_hs = c_arvalid && c_arready;
  wire c_aw_hs = c_awvalid && c_awready;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt           <= 32'b0;
      commit_seen   <= 1'b0;
      confwr_seen   <= 1'b0;
      num_seen      <= 1'b0;
      last_cmt_pc   <= 32'b0;
      last_axi_addr <= 32'b0;
    end else begin
      if (cnt < FIRE_CNT) cnt <= cnt + 32'd1;
      if (cmt_pulse) begin
        commit_seen <= 1'b1;
        last_cmt_pc <= cmt_pc;
      end
      if (c_ar_hs) last_axi_addr <= c_araddr;
      if (c_aw_hs) begin
        last_axi_addr <= c_awaddr;
        if (c_awaddr[31:16] == 16'hbfaf) confwr_seen <= 1'b1;
        if (c_awaddr == NUM_ADDR)        num_seen    <= 1'b1;
      end
    end
  end

  wire fire = (cnt >= FIRE_CNT) && !num_seen;

  // ---------------- 夺取 + 信标 FSM ----------------
  localparam D_IDLE = 3'd0, D_DRAIN = 3'd1, D_A1 = 3'd2, D_B1 = 3'd3,
             D_A2   = 3'd4, D_B2    = 3'd5, D_DONE = 3'd6;

  reg [2:0]  state;
  reg [3:0]  drain_cnt;
  reg [1:0]  code_r;
  reg [31:0] payload_r;
  reg        aw_sent, w_sent;

  wire seize = (state != D_IDLE);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= D_IDLE;
      drain_cnt <= 4'b0;
      code_r    <= 2'b0;
      payload_r <= 32'b0;
      aw_sent   <= 1'b0;
      w_sent    <= 1'b0;
    end else begin
      case (state)
        D_IDLE: begin
          if (fire) begin
            code_r    <= !commit_seen ? 2'b01 :
                         !confwr_seen ? 2'b10 : 2'b11;
            payload_r <= (commit_seen && !confwr_seen) ? last_cmt_pc
                                                       : last_axi_addr;
            drain_cnt <= 4'b0;
            state     <= D_DRAIN;
          end
        end
        D_DRAIN: begin  // 等滞留响应被吸收几拍
          drain_cnt <= drain_cnt + 4'd1;
          if (drain_cnt == 4'd15) begin
            aw_sent <= 1'b0;
            w_sent  <= 1'b0;
            state   <= D_A1;
          end
        end
        D_A1: begin  // 写 NUM_ADDR：AW+W 同发，等各自拍手
          if (e_awready) aw_sent <= 1'b1;
          if (e_wready)  w_sent  <= 1'b1;
          if ((aw_sent || e_awready) && (w_sent || e_wready)) state <= D_B1;
        end
        D_B1: begin
          // 只认信标自己的 B（bid==4'hf）；CPU 滞留 B（bid==1）由 e_bready=1 吸收
          if (e_bvalid && e_bid == 4'hf) begin
            aw_sent <= 1'b0;
            w_sent  <= 1'b0;
            state   <= D_A2;
          end
        end
        D_A2: begin  // 写 LED_RG0_ADDR
          if (e_awready) aw_sent <= 1'b1;
          if (e_wready)  w_sent  <= 1'b1;
          if ((aw_sent || e_awready) && (w_sent || e_wready)) state <= D_B2;
        end
        D_B2: begin
          if (e_bvalid && e_bid == 4'hf) state <= D_DONE;
        end
        D_DONE: state <= D_DONE;  // 保持夺取：吸收一切晚归响应
        default: state <= D_IDLE;
      endcase
    end
  end

  // 信标 AXI 输出（写地址/数据通道）
  wire        d_awvalid = (state == D_A1 || state == D_A2) && !aw_sent;
  wire        d_wvalid  = (state == D_A1 || state == D_A2) && !w_sent;
  wire [31:0] d_awaddr  = (state == D_A1) ? NUM_ADDR : LED_RG0_ADDR;
  wire [31:0] d_wdata   = (state == D_A1) ? payload_r : {30'b0, code_r};

  // ----------------  mux ----------------
  assign e_arid    = c_arid;
  assign e_araddr  = c_araddr;
  assign e_arlen   = c_arlen;
  assign e_arsize  = c_arsize;
  assign e_arburst = c_arburst;
  assign e_arlock  = c_arlock;
  assign e_arcache = c_arcache;
  assign e_arprot  = c_arprot;
  assign e_arvalid = seize ? 1'b0 : c_arvalid;
  assign c_arready = seize ? 1'b0 : e_arready;

  assign c_rid     = e_rid;
  assign c_rdata   = e_rdata;
  assign c_rresp   = e_rresp;
  assign c_rlast   = e_rlast;
  assign c_rvalid  = seize ? 1'b0 : e_rvalid;   // 夺取期间外部 R 被下方吸收
  assign e_rready  = seize ? 1'b1 : c_rready;   // 吸收并丢弃

  assign e_awid    = seize ? 4'hf    : c_awid;
  assign e_awaddr  = seize ? d_awaddr : c_awaddr;
  assign e_awlen   = seize ? 4'd0    : c_awlen;
  assign e_awsize  = seize ? 3'd2    : c_awsize;
  assign e_awburst = seize ? 2'b01   : c_awburst;
  assign e_awlock  = seize ? 2'b0    : c_awlock;
  assign e_awcache = seize ? 4'b0    : c_awcache;
  assign e_awprot  = seize ? 3'b0    : c_awprot;
  assign e_awvalid = seize ? d_awvalid : c_awvalid;
  assign c_awready = seize ? 1'b0 : e_awready;

  assign e_wid     = seize ? 4'hf    : c_wid;
  assign e_wdata   = seize ? d_wdata : c_wdata;
  assign e_wstrb   = seize ? 4'hf    : c_wstrb;
  assign e_wlast   = seize ? 1'b1    : c_wlast;
  assign e_wvalid  = seize ? d_wvalid : c_wvalid;
  assign c_wready  = seize ? 1'b0 : e_wready;

  assign c_bid     = e_bid;
  assign c_bresp   = e_bresp;
  assign c_bvalid  = seize ? 1'b0 : e_bvalid;
  assign e_bready  = seize ? 1'b1 : c_bready;   // 夺取期间吸收 B（含信标自己的）

endmodule
