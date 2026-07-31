// ============================================================================
// dcache.v — 8KB 直接映射 DCache（write-through + no-write-allocate）
// 见 SPEC.md §8.7。纯 Verilog-2001。
//
// 位置：lsu <-> axi_arbiter 之间的 shim。对 lsu 保持原"单拍 AXI"语义，
// lsu 零改动。组织：512 组 x 16B 行，index=addr[12:4]，tag=addr[31:13]+valid。
//
// cached 区判定：addr[31:24]==8'h1c（程序区）|| addr[31:28]==4'h0（DDR3 数据区，v4 扩展；其余 MMIO/外设透传）
//   load hit  ：AR 握手后 1 拍回数据（BRAM 同步读 + 组合判 tag），不占 AXI
//   load miss ：自行发 16B burst refill（arlen=3，行对齐），4 beat 组行，
//               末 beat 同拍组合回 lsu 对应字 + 写 BRAM（教训：跨拍必锁存）
//   uncached  ：AR/R 透传（arlen=0 单拍），绝不分配（MMIO 读有副作用）
// store（sb drain）：AW/W/B 纯透传（write-through 天然成立）；
//   W 握手拍对 cached 地址【无条件 invalidate 该组】（清 valid 不比 tag——
//   tag 在 BRAM 同步读同拍拿不到；误伤同组异 tag 行只损失一次未来 miss）
//
// 正确性论证（单核 + C6 阻塞，lsu 无 sb->load 前递）：
//  - load accept 时 sb 必空（block_load=|sb_valid，IQ 门控发射）→ 所有更老
//    store 已 drain 完（B 已回）→ 其 invalidate 早已执行 → load 不可能读到
//    被更老 store 覆盖的陈旧行
//  - load 在途期间的年幼 store drain：程序序上 load 应取旧值 → hit/refill
//    回旧数据均正确；该 store 的 invalidate 保证后续 load 取新值
//  - refill 在途遇同组 store invalidate：置 inv_block_fill，末 beat 写行时
//    valid=0（防"先清后被 refill 复活"的陈旧行）
// 写口仲裁（tag_ram 单写口）：
//   refill 末 beat 与 invalidate 同拍：同组 -> valid=0 写入（invalidate 赢，
//   数据照写无害）；异组 -> invalidate 锁存 inv_pend 下拍补写（此时 lsu 被
//   refill 卡住无 load 在途，补写窗口安全）
// AXI 教训前置（icache 五连修）：
//   - 末 beat 同拍组合写 BRAM + 组合回 rvalid（跨拍引用 m_rdata 必被新相位污染）
//   - arvalid 置位后等 else if (m_arready) 才判握手（防自清丢 AR）
// ============================================================================

module dcache(
  input clk, input rst_n,
  // 上游：LSU（原单拍 AXI 语义）
  input  s_arvalid, output s_arready, input  [31:0] s_araddr,
  output s_rvalid, output [31:0] s_rdata,
  input  s_awvalid, output s_awready, input  [31:0] s_awaddr,
  input  s_wvalid,  output s_wready,  input  [31:0] s_wdata, input [3:0] s_wstrb,
  input  s_bvalid,
  // 下游：axi_arbiter（LSU 侧，支持 arlen 可变）
  output m_arvalid, input m_arready, output [31:0] m_araddr, output [3:0] m_arlen,
  input  m_rvalid, input [31:0] m_rdata, input m_rlast,
  output m_awvalid, input m_awready, output [31:0] m_awaddr,
  output m_wvalid,  input m_wready,  output [31:0] m_wdata, output [3:0] m_wstrb,
  output m_bvalid
);

  // ---------------- 写通道：纯透传 + W 握手监听 ----------------
  assign m_awvalid = s_awvalid;
  assign m_awaddr  = s_awaddr;
  assign s_awready = m_awready;
  assign m_wvalid  = s_wvalid;
  assign m_wdata   = s_wdata;
  assign m_wstrb   = s_wstrb;
  assign s_wready  = m_wready;
  assign m_bvalid  = s_bvalid;

  // AW 先握手、W 后握手时锁存地址（lsu 单 outstanding，B 前 s_awaddr 不变，双保险）
  reg        wr_aw_done;
  reg [31:0] wr_addr_r;
  wire aw_hs = s_awvalid && m_awready;
  wire wr_hs = s_wvalid  && m_wready;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_aw_done <= 1'b0;
      wr_addr_r  <= 32'b0;
    end else begin
      if (aw_hs) begin
        wr_addr_r  <= s_awaddr;
        wr_aw_done <= 1'b1;
      end
      if (s_bvalid) wr_aw_done <= 1'b0;   // B 回，一笔写结束
    end
  end
  wire [31:0] wr_addr = wr_aw_done ? wr_addr_r : s_awaddr;
  wire        inv_req = wr_hs && ((wr_addr[31:24] == 8'h1c) || (wr_addr[31:28] == 4'h0));
  wire [8:0]  inv_idx = wr_addr[12:4];

  // ---------------- BRAM 阵列 ----------------
  (* ram_style = "block" *) reg [127:0] data_ram [0:511];
  (* ram_style = "block" *) reg [19:0]  tag_ram  [0:511];   // {valid, tag[18:0]}
  reg [127:0] data_d;
  reg [19:0]  tag_d;
  reg [95:0]  line_buf;     // refill 前 3 beat；第 4 beat 直接进 fill_line
  reg [1:0]   beat_cnt;

  // ---------------- 读 FSM ----------------
  localparam S_RUN    = 2'd0;
  localparam S_REFILL = 2'd1;
  localparam S_UC     = 2'd2;

  reg [1:0]  state;
  reg        pend;          // AR 已握手，次拍判定 hit/miss/uc 中
  reg [31:0] s_addr_r;
  reg        cached_r;
  reg        m_arvalid_r;
  reg [31:0] m_araddr_r;
  reg [3:0]  m_arlen_r;
  reg        ar_sent;
  reg        inv_block_fill;   // refill 期间同组 invalidate：末 beat valid=0
  reg        inv_pend;         // 末 beat 异组 invalidate 抢写口失败：下拍补写
  reg [8:0]  inv_idx_r;

  wire cached_req = (s_araddr[31:24] == 8'h1c) || (s_araddr[31:28] == 4'h0);
  assign s_arready = (state == S_RUN) && !pend;
  wire s_hs = s_arvalid && s_arready;

  // 次拍判定（BRAM 同步读已出数）
  wire tag_hit = tag_d[19] && (tag_d[18:0] == s_addr_r[31:13]);
  wire [31:0] hit_word  = data_d[s_addr_r[3:2]*32 +: 32];
  wire [127:0] fill_line = {m_rdata, line_buf};
  wire [31:0] fill_word  = fill_line[s_addr_r[3:2]*32 +: 32];

  wire refill_last = (state == S_REFILL) && ar_sent && m_rvalid && m_rlast;
  wire uc_done     = (state == S_UC)     && ar_sent && m_rvalid;

  assign s_rvalid = (pend && cached_r && tag_hit) || refill_last || uc_done;
  assign s_rdata  = (state == S_UC) ? m_rdata
                  : (state == S_REFILL) ? fill_word : hit_word;

  assign m_arvalid = m_arvalid_r;
  assign m_araddr  = m_araddr_r;
  assign m_arlen   = m_arlen_r;

  // BRAM 读：AR 握手拍组合发起（同步读，次拍出数）
  wire rd_en  = s_hs && cached_req;
  wire [8:0] rd_idx = s_araddr[12:4];

  // 写口仲裁
  wire [8:0] wr_idx = s_addr_r[12:4];   // refill 行号
  wire refill_same_inv = inv_req && (inv_idx == wr_idx);   // 当拍同组
  // inv 当拍可写：写口空闲（无 refill 末拍、无补写）且非"refill 期间同组"
  wire inv_take_now = inv_req && !refill_last && !inv_pend
                    && !((state == S_REFILL) && refill_same_inv);

  integer k;
  initial begin
    for (k = 0; k < 512; k = k + 1) tag_ram[k] = 20'b0;
  end

  always @(posedge clk) begin
    if (rd_en) begin
      data_d <= data_ram[rd_idx];
      tag_d  <= tag_ram[rd_idx];
    end
    // 写口优先级：① inv_pend 补写 ② refill 末 beat ③ inv 当拍
    if (inv_pend) begin
      tag_ram[inv_idx_r] <= 20'b0;                // valid=0 即可，tag 无所谓
    end else if (refill_last) begin
      data_ram[wr_idx] <= fill_line;
      tag_ram[wr_idx]  <= {(inv_block_fill || refill_same_inv) ? 1'b0 : 1'b1,
                           s_addr_r[31:13]};
    end else if (inv_take_now) begin
      tag_ram[inv_idx] <= 20'b0;
    end
  end

  // ---------------- 主时序 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state          <= S_RUN;
      pend           <= 1'b0;
      s_addr_r       <= 32'b0;
      cached_r       <= 1'b0;
      m_arvalid_r    <= 1'b0;
      m_araddr_r     <= 32'b0;
      m_arlen_r      <= 4'b0;
      ar_sent        <= 1'b0;
      line_buf       <= 96'b0;
      beat_cnt       <= 2'b0;
      inv_block_fill <= 1'b0;
      inv_pend       <= 1'b0;
      inv_idx_r      <= 9'b0;
    end else begin
      // ---- AR 握手接收（S_RUN） ----
      if (s_hs) begin
        pend     <= 1'b1;
        s_addr_r <= s_araddr;
        cached_r <= cached_req;
      end

      // ---- 次拍判定：uc / miss 发起 AXI（置位同拍不判握手，教训5） ----
      if (m_arvalid_r && m_arready) begin
        m_arvalid_r <= 1'b0;
        ar_sent     <= 1'b1;
      end else if (pend && !cached_r) begin
        pend        <= 1'b0;
        state       <= S_UC;
        m_arvalid_r <= 1'b1;
        m_araddr_r  <= s_addr_r;                    // 字地址单拍
        m_arlen_r   <= 4'd0;
      end else if (pend && cached_r && !tag_hit) begin
        pend           <= 1'b0;
        state          <= S_REFILL;
        m_arvalid_r    <= 1'b1;
        m_araddr_r     <= {s_addr_r[31:4], 4'b0};   // 行对齐 burst
        m_arlen_r      <= 4'd3;
        beat_cnt       <= 2'b0;
        inv_block_fill <= 1'b0;
      end else if (pend) begin
        pend <= 1'b0;                               // hit：组合已回 rvalid
      end

      // ---- REFILL：收 4 beat（每 beat 锁存，末 beat 组合回 + 写 BRAM） ----
      if ((state == S_REFILL) && ar_sent && m_rvalid) begin
        if (!m_rlast) begin
          line_buf[beat_cnt*32 +: 32] <= m_rdata;
          beat_cnt <= beat_cnt + 2'd1;
        end else begin
          state    <= S_RUN;
          ar_sent  <= 1'b0;
          beat_cnt <= 2'b0;
        end
      end

      // ---- UC：单拍透传 R ----
      if (uc_done) begin
        state   <= S_RUN;
        ar_sent <= 1'b0;
      end

      // ---- refill 期间同组 invalidate：末 beat 写 valid=0 ----
      if ((state == S_REFILL) && inv_req && (inv_idx == wr_idx))
        inv_block_fill <= 1'b1;

      // ---- 末 beat 异组 invalidate 抢写口失败：锁存补写 ----
      if (inv_req && (refill_last || inv_pend)
          && !((state == S_REFILL) && (inv_idx == wr_idx))) begin
        inv_pend  <= 1'b1;
        inv_idx_r <= inv_idx;
      end else if (inv_pend) begin
        inv_pend <= 1'b0;                           // 补写完成
      end
    end
  end

endmodule
