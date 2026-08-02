// ============================================================================
// dcache.v — 8KB 直接映射 DCache（write-back + write-allocate）
// 见 DCACHE_WB_SPEC.md（单一事实源）。纯 Verilog-2001。
// Design refers to OpenLA500 (https://gitee.com/loongson-edu/open-la500), Mulan PSL v2.
//
// 位置：lsu <-> axi_arbiter 之间的 shim。对 lsu 保持原"单拍 AXI"语义，
// lsu 零改动。组织：512 组 x 16B 行，index=addr[12:4]，
// tag_ram = 21bit {valid, dirty, tag[18:0]}。
//
// cached 区判定：addr[31:24]==8'h1c（程序区）|| addr[31:28]==4'h0（DDR3 数据区）；
// 其余（MMIO/外设）单拍透传、绝不分配（MMIO 读写有副作用）。
//
//   load hit  ：AR 握手后 1 拍组合回 rvalid（BRAM 同步读 + 组合判 tag），不占 AXI
//   load miss ：脏 victim 先写回 burst（awlen=3, 4xW wstrb=F, B 内部消费）再
//               refill burst（arlen=3，行对齐）；净 victim 直接 refill。
//               末 beat 同拍组合回 lsu 对应字 + 写 BRAM(dirty=0)
//   store hit ：决策拍写 BRAM（按 wstrb 字节 merge）+ tag dirty 置 1 +
//               同拍回 B 脉冲，不占 AXI
//   store miss：write-allocate——脏 victim 先写回（B 内部消费）再 refill；
//               末 beat 同拍组合：store 字 merge 进 fill 行写 BRAM(dirty=1) + 回 B
//   uncached  ：load AR/R 单拍透传（arlen=0）；store AW/W/B 单拍透传
//               （awlen=0, wlast=1），B 透传回 LSU；均不分配
//
// B 脉冲恰好一次（LSU 无 bready，多弹/漏弹 sb 都是致命错）：
//   store hit→决策拍 1 次；store miss→refill 末拍 1 次；UC store→透传 1 次；
//   写回（S_L_WB/S_S_WB）收到的 arbiter B 内部消费，绝不外泄给 LSU
//   （store 触发的写回若提前回 B 会提前弹 sb——致命）。
//
// 正确性论证（规格 §4 不变式，结构性保证）：
//  - store drain 与 load 不并发（ROB 提交序 + C6 门控）⇒ store 写 BRAM 与
//    refill 写 BRAM 永不撞写口；无需 inv_req/inv_pend/inv_block_fill（已删）
//  - load 被接受时 sb 必空 ⇒ 所有更老 store 已 apply 进 cache，无陈旧读
//  - 单 outstanding：FSM 串行，下游至多一笔读或写在途
//
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
  // 下游：axi_arbiter（LSU 侧，arlen/awlen 可变）
  output m_arvalid, input m_arready, output [31:0] m_araddr, output [3:0] m_arlen,
  input  m_rvalid, input [31:0] m_rdata, input m_rlast,
  output m_awvalid, input m_awready, output [31:0] m_awaddr, output [3:0] m_awlen,
  output m_wvalid,  input m_wready,  output [31:0] m_wdata, output [3:0] m_wstrb,
  output m_wlast,
  output m_bvalid
);

  // ---------------- BRAM 阵列 ----------------
  (* ram_style = "block" *) reg [127:0] data_ram [0:511];
  (* ram_style = "block" *) reg [20:0]  tag_ram  [0:511];   // {valid, dirty, tag[18:0]}
  reg [127:0] data_d;
  reg [20:0]  tag_d;
  reg [95:0]  line_buf;     // refill 前 3 beat；第 4 beat 直接进 fill_line
  reg [1:0]   beat_cnt;

  // ---------------- FSM 状态 ----------------
  localparam S_INIT   = 3'd0;   // 复位后 512 拍逐行清 valid+dirty
  localparam S_RUN    = 3'd1;   // 空闲，接收 load AR / store AW+W
  localparam S_L_WB   = 3'd2;   // load miss 脏 victim：写回 burst → S_L_FILL
  localparam S_L_FILL = 3'd3;   // load refill burst，末拍回 rvalid + 写行(dirty=0)
  localparam S_S_WB   = 3'd4;   // store miss 脏 victim：写回 burst → S_S_FILL
  localparam S_S_FILL = 3'd5;   // store refill，末拍 merge 写行(dirty=1) + 回 B
  localparam S_UC     = 3'd6;   // uncached load 透传（arlen=0）
  localparam S_UCW    = 3'd7;   // uncached store 透传（awlen=0 单拍）

  reg [2:0]  state;
  reg [8:0]  init_idx;          // S_INIT 逐行清零计数

  // load 通道
  reg        pend;              // AR 已握手，次拍判定 hit/miss/uc 中
  reg [31:0] s_addr_r;
  reg        cached_r;
  // store 通道
  reg        spend;             // AW+W 已握手，次拍判定 hit/miss/uc 中
  reg [31:0] st_addr_r;
  reg [31:0] st_data_r;
  reg [3:0]  st_strb_r;
  reg        st_cached_r;
  // 下游 AR
  reg        m_arvalid_r;
  reg [31:0] m_araddr_r;
  reg [3:0]  m_arlen_r;
  reg        ar_sent;
  // 下游 AW/W（写回 burst 或 UC store 透传）
  reg        m_awvalid_r;
  reg        m_wvalid_r;
  reg [31:0] wb_addr_r;         // 写回行地址 {victim_tag, index, 4'b0}
  reg [127:0] wb_line_r;        // 写回行数据
  reg [1:0]   w_beat;           // 写回 W beat 计数

  // ---------------- 上游握手 ----------------
  wire cached_req    = (s_araddr[31:24] == 8'h1c) || (s_araddr[31:28] == 4'h0);
  wire st_cached_req = (s_awaddr[31:24] == 8'h1c) || (s_awaddr[31:28] == 4'h0);

  // load/store 不并发（不变式1），两通道共用同一组 ready 条件
  assign s_arready = (state == S_RUN) && !pend && !spend;
  assign s_awready = (state == S_RUN) && !pend && !spend;
  assign s_wready  = (state == S_RUN) && !pend && !spend;
  wire s_hs  = s_arvalid && s_arready;
  wire st_hs = s_awvalid && s_wvalid && s_awready && s_wready;  // LSU 同拍两通道

  // ---------------- 次拍判定（BRAM 同步读已出数） ----------------
  wire        tag_hit    = tag_d[20] && (tag_d[18:0] == s_addr_r[31:13]);
  wire        victim_d   = tag_d[20] && tag_d[19];            // 脏 victim
  wire [31:0] hit_word   = data_d[s_addr_r[3:2]*32 +: 32];
  wire        st_hit     = st_cached_r && tag_d[20] && (tag_d[18:0] == st_addr_r[31:13]);
  wire        st_victim_d= tag_d[20] && tag_d[19];

  // refill 组行 / 末拍
  wire [127:0] fill_line  = {m_rdata, line_buf};
  wire [31:0]  fill_word  = fill_line[s_addr_r[3:2]*32 +: 32];
  wire l_fill_last = (state == S_L_FILL) && ar_sent && m_rvalid && m_rlast;
  wire s_fill_last = (state == S_S_FILL) && ar_sent && m_rvalid && m_rlast;
  wire uc_done     = (state == S_UC)     && ar_sent && m_rvalid;
  wire wb_b_done   = (state == S_L_WB || state == S_S_WB) && s_bvalid;  // 内部消费

  // store merge（字节粒度，st_addr_r[3:2] 指示的字）
  wire [31:0]  mask32    = {{8{st_strb_r[3]}},{8{st_strb_r[2]}},
                            {8{st_strb_r[1]}},{8{st_strb_r[0]}}};
  wire [127:0] mask_line = {{96{1'b0}}, mask32}   << {st_addr_r[3:2], 5'b0};
  wire [127:0] st_line   = {{96{1'b0}}, st_data_r} << {st_addr_r[3:2], 5'b0};
  // store hit：与 BRAM 读出的行 merge
  wire [127:0] hit_merge_line  = (data_d    & ~mask_line) | (st_line & mask_line);
  // store miss：与 refill 行 merge（write-allocate）
  wire [127:0] fill_merge_line = (fill_line & ~mask_line) | (st_line & mask_line);

  // ---------------- 上游回应 ----------------
  // load：拍1 hit 组合回 / refill 末拍组合回 / UC 单拍回（逐拍与现版一致）
  assign s_rvalid = (pend && cached_r && tag_hit) || l_fill_last || uc_done;
  assign s_rdata  = (state == S_UC) ? m_rdata
                  : (state == S_L_FILL) ? fill_word : hit_word;

  // B 脉冲恰好一次：store hit 决策拍 / store refill 末拍 / UC store 透传
  assign m_bvalid = (spend && st_hit) || s_fill_last
                  || ((state == S_UCW) && s_bvalid);

  // ---------------- 下游 AXI ----------------
  assign m_arvalid = m_arvalid_r;
  assign m_araddr  = m_araddr_r;
  assign m_arlen   = m_arlen_r;

  assign m_awvalid = m_awvalid_r;
  assign m_awaddr  = (state == S_UCW) ? st_addr_r : wb_addr_r;
  assign m_awlen   = (state == S_UCW) ? 4'd0 : 4'd3;
  assign m_wvalid  = m_wvalid_r;
  assign m_wdata   = (state == S_UCW) ? st_data_r : wb_line_r[w_beat*32 +: 32];
  assign m_wstrb   = (state == S_UCW) ? st_strb_r : 4'hF;
  assign m_wlast   = (state == S_UCW) ? 1'b1 : (w_beat == 2'd3);

  // ---------------- BRAM 读：握手拍组合发起（同步读，次拍出数） ----------------
  // load/store 不并发（不变式1），单读口无冲突
  wire       rd_en  = (s_hs && cached_req) || (st_hs && st_cached_req);
  wire [8:0] rd_idx = s_hs ? s_araddr[12:4] : s_awaddr[12:4];

  integer k;
  initial begin
    for (k = 0; k < 512; k = k + 1) tag_ram[k] = 21'b0;
  end

  // ---------------- BRAM 写口（各写源 FSM 互斥） ----------------
  always @(posedge clk) begin
    if (rd_en) begin
      data_d <= data_ram[rd_idx];
      tag_d  <= tag_ram[rd_idx];
    end
    if (state == S_INIT) begin
      tag_ram[init_idx] <= 21'b0;                       // 清 valid+dirty
    end else if (spend && st_hit) begin                 // store hit：merge 写 + dirty=1
      data_ram[st_addr_r[12:4]] <= hit_merge_line;
      tag_ram [st_addr_r[12:4]] <= {1'b1, 1'b1, tag_d[18:0]};
    end else if (l_fill_last) begin                     // load refill：写行 dirty=0
      data_ram[s_addr_r[12:4]] <= fill_line;
      tag_ram [s_addr_r[12:4]] <= {1'b1, 1'b0, s_addr_r[31:13]};
    end else if (s_fill_last) begin                     // store refill：merge 写 dirty=1
      data_ram[st_addr_r[12:4]] <= fill_merge_line;
      tag_ram [st_addr_r[12:4]] <= {1'b1, 1'b1, st_addr_r[31:13]};
    end
  end

  // ---------------- 主时序 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_INIT;
      init_idx    <= 9'd0;
      pend        <= 1'b0;
      s_addr_r    <= 32'b0;
      cached_r    <= 1'b0;
      spend       <= 1'b0;
      st_addr_r   <= 32'b0;
      st_data_r   <= 32'b0;
      st_strb_r   <= 4'b0;
      st_cached_r <= 1'b0;
      m_arvalid_r <= 1'b0;
      m_araddr_r  <= 32'b0;
      m_arlen_r   <= 4'b0;
      ar_sent     <= 1'b0;
      m_awvalid_r <= 1'b0;
      m_wvalid_r  <= 1'b0;
      wb_addr_r   <= 32'b0;
      wb_line_r   <= 128'b0;
      w_beat      <= 2'b0;
      line_buf    <= 96'b0;
      beat_cnt    <= 2'b0;
    end else begin
      // ---- S_INIT：复位后 512 拍逐行清 valid+dirty，完成才进 S_RUN ----
      if (state == S_INIT) begin
        if (init_idx == 9'd511) begin
          state    <= S_RUN;
          init_idx <= 9'd0;
        end else begin
          init_idx <= init_idx + 9'd1;
        end
      end

      // ---- 上游握手接收（S_RUN） ----
      if (s_hs) begin
        pend     <= 1'b1;
        s_addr_r <= s_araddr;
        cached_r <= cached_req;
      end
      if (st_hs) begin
        spend       <= 1'b1;
        st_addr_r   <= s_awaddr;
        st_data_r   <= s_wdata;
        st_strb_r   <= s_wstrb;
        st_cached_r <= st_cached_req;
      end

      // ---- 下游 AR：置位后等 else if (m_arready) 才判握手（教训5） ----
      if (m_arvalid_r && m_arready) begin
        m_arvalid_r <= 1'b0;
        ar_sent     <= 1'b1;
      end else if (pend && !cached_r) begin
        m_arvalid_r <= 1'b1;                          // UC load：字地址单拍
        m_araddr_r  <= s_addr_r;
        m_arlen_r   <= 4'd0;
      end else if (pend && cached_r && !tag_hit && !victim_d) begin
        m_arvalid_r <= 1'b1;                          // load miss 净 victim：直接 refill
        m_araddr_r  <= {s_addr_r[31:4], 4'b0};
        m_arlen_r   <= 4'd3;
      end else if (spend && st_cached_r && !st_hit && !st_victim_d) begin
        m_arvalid_r <= 1'b1;                          // store miss 净 victim：直接 refill
        m_araddr_r  <= {st_addr_r[31:4], 4'b0};
        m_arlen_r   <= 4'd3;
      end else if (wb_b_done) begin
        m_arvalid_r <= 1'b1;                          // 写回完成后 refill
        m_araddr_r  <= (state == S_L_WB) ? {s_addr_r[31:4], 4'b0}
                                         : {st_addr_r[31:4], 4'b0};
        m_arlen_r   <= 4'd3;
      end

      // ---- 下游 AW/W：写回 burst（awlen=3,4xW）或 UC store 单拍透传 ----
      if (m_awvalid_r && m_awready)
        m_awvalid_r <= 1'b0;
      else if ((pend  && cached_r    && !tag_hit && victim_d)
            || (spend && st_cached_r && !st_hit  && st_victim_d)
            || (spend && !st_cached_r))
        m_awvalid_r <= 1'b1;

      if (m_wvalid_r && m_wready) begin
        if ((state == S_L_WB || state == S_S_WB) && (w_beat != 2'd3))
          w_beat <= w_beat + 2'd1;                    // burst 中拍：推进 beat
        else begin
          m_wvalid_r <= 1'b0;                         // 末拍（或 UC 单拍）握手完成
          w_beat     <= 2'b0;
        end
      end else if ((pend  && cached_r    && !tag_hit && victim_d)
                || (spend && st_cached_r && !st_hit  && st_victim_d)
                || (spend && !st_cached_r)) begin
        m_wvalid_r <= 1'b1;
        w_beat     <= 2'b0;
      end

      // ---- load 次拍判定 ----
      if (pend) begin
        if (!cached_r) begin
          pend  <= 1'b0;
          state <= S_UC;
        end else if (tag_hit) begin
          pend  <= 1'b0;                              // hit：组合已回 rvalid
        end else if (victim_d) begin
          pend      <= 1'b0;                          // miss 脏 victim：先写回
          state     <= S_L_WB;
          wb_addr_r <= {tag_d[18:0], s_addr_r[12:4], 4'b0};
          wb_line_r <= data_d;
        end else begin
          pend     <= 1'b0;                           // miss 净 victim：直接 refill
          state    <= S_L_FILL;
          beat_cnt <= 2'b0;
        end
      end

      // ---- store 次拍判定 ----
      if (spend) begin
        if (!st_cached_r) begin
          spend <= 1'b0;                              // UC store：AW/W 单拍透传
          state <= S_UCW;
        end else if (st_hit) begin
          spend <= 1'b0;                              // hit：BRAM 写 + 组合已回 B
        end else if (st_victim_d) begin
          spend     <= 1'b0;                          // miss 脏 victim：先写回
          state     <= S_S_WB;
          wb_addr_r <= {tag_d[18:0], st_addr_r[12:4], 4'b0};
          wb_line_r <= data_d;
        end else begin
          spend    <= 1'b0;                           // miss 净 victim：直接 refill
          state    <= S_S_FILL;
          beat_cnt <= 2'b0;
        end
      end

      // ---- 写回的 arbiter B：内部消费，绝不外泄（不变式4） ----
      if (wb_b_done) begin
        state    <= (state == S_L_WB) ? S_L_FILL : S_S_FILL;
        ar_sent  <= 1'b0;
        beat_cnt <= 2'b0;
      end

      // ---- FILL：收 4 beat（前 3 beat 锁存，末 beat 组合回 + 组合写 BRAM） ----
      if ((state == S_L_FILL || state == S_S_FILL) && ar_sent && m_rvalid) begin
        if (!m_rlast) begin
          line_buf[beat_cnt*32 +: 32] <= m_rdata;
          beat_cnt <= beat_cnt + 2'd1;
        end else begin
          state    <= S_RUN;
          ar_sent  <= 1'b0;
          beat_cnt <= 2'b0;
        end
      end

      // ---- UC load：单拍透传 R ----
      if (uc_done) begin
        state   <= S_RUN;
        ar_sent <= 1'b0;
      end

      // ---- UC store：B 透传回 LSU（组合），一拍后归位 ----
      if ((state == S_UCW) && s_bvalid)
        state <= S_RUN;
    end
  end

endmodule
