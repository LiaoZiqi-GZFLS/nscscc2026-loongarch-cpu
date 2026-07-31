// ============================================================================
// icache.v — 16KB 2 路组相联指令 Cache（v2.8：四行 refill + S_WAIT 出口复查）
// - v2.8 四行 refill（Stage 32）：需求 cached miss 且 +63B 全在 cached 区 →
//   arlen=15 一次取 4 行（64B），后台收数窗口扩到 beat4-15，覆盖 8 拍消费。
//   删除 pf2_early 提前 resp（rlast 在 beat15 时 pf2_buf 装的是第 4 行，提前
//   resp 必错数据）；S_WAIT 出口统一改 recheck 复查 tag——bg 填的 2/3/4 行
//   此时已写 BRAM，命中即省一次 burst，未命中走常规 miss 重发（等效原路径）。
//   关键坑：bg 行写地址必须用 beat3 拍锁存的 pf2_addr——bg 窗口内新 miss
//   （进 S_WAIT）会改写 miss_addr，组合引用把 2/3/4 行写到错位地址（实测
//   test1 即挂）。lean 316,790→304,467（-3.9%），SoC 318,908→306,952（-3.7%）。
// - v2.4b 后台填第二行（Stage 31h 续）：v2.4a 双行 refill 的 beat4-7 期间
//   state 停在 S_REFILL，前端空等 4 拍 → 改为 beat3 需求行齐照常 resp 后
//   【立即回 S_RUN】，bg_fill=1 后台收 beat4-7 填第二行，期间 hit 照服务；
//   期间新需求 miss/uc 进 S_WAIT 等 rlast 后再发起（AXI 单 outstanding）。
//   提前 resp：req 的正是正在填的第二行时，rlast 拍组合 {mem_rdata,pf2_buf}
//   直接 resp（pf2_early_run / pf2_early_wait 两条路径）。预取发起加 !bg_fill。
//   lean 实测 347,963→330,141（再 -4.5%，IPC 0.265→0.278；累计 -14.2%）。
//   教训：bg_fill 收数用独立计数器 pfb（与需求行 beat 解耦）——共享计数器
//   被两路逻辑写时，后写赢的隐性优先级是数据错位温床（t6/t7 实测实证）。
// - v2.4a 双行 refill（保留）：需求 cached miss 且下一行仍 cached → arlen=7
//   一次取 2 行；预取/uc 保持 arlen=3。redirect 白取是已知权衡。
// - 组织: 2 路 × 512 组 × 16B 行 = 16KB；index=addr[12:4]，tag=addr[31:13]+valid
// - v2.3（Stage 31h 数据驱动）：lean 实测 ic_busy=54.3% 周期，其中 99.1% 是
//   需求 miss refill（8KB 直接映射 vs 477KB 代码，miss 率≈10%）→ 扩容+2 路。
//   C1 放宽被同组数据否决（单发射中 C1 仅 0.7%，rdy_limit 83.7% 根因是前端
//   供给不足）。预取仅占 ic_busy 0.8%，保留不变。
// - 接口（与 frontend 紧耦合，全流水，v2 起不变）：
//     拍 N:   req_valid + req_addr（16B 块基址）→ 两路 BRAM 同步读
//     拍 N+1: 任一路 hit → resp_valid=1 + resp_line（2:1 MUX，组合判 tag）
//             全 miss → 锁存地址+victim 路进 S_REFILL，resp_valid=0 直到完成
// - cached 区判定: addr[31:24]==8'h1c || addr[31:28]==4'h0（v4 扩展 DDR3 区）；uncached 走 S_UC 透传 4 beat 不分配
// - 替换：每组 1bit 伪 LRU（victim[] 寄存器数组异步读）；hit 拍置 victim
//   为另一路；miss 锁存拍组合读 victim 锁存 refill_way；refill 写后翻转。
//   复位全 0（先填 way0 再 way1，冷启动天然均衡）。
// - BRAM 可推断: 同步读；initial 清 valid；同拍读写同地址仅致多余 miss，
//   不影响正确性（读出旧行 valid=0 或异 tag 均走 refill）
// - v2.1 链式顺序预取（保留）：S_RUN 中 resp hit 拍锁存 pf_addr=行基址+16
//   （仍 cached 才置位）；仅在 frontend req 空闲拍发起，不挡需求；需求
//   miss/uc 优先。预取复用 S_REFILL + pf 标志：照写 victim 路 BRAM 但
//   【不 resp】（refill_done 排除 pf）。icache 不知 redirect，预取填行
//   永远无害（resp_kill 由 frontend 处理在途需求 resp）。
// ============================================================================
`include "la32_defs.vh"

module icache(
  input              clk,
  input              rst_n,
  // req/resp 取指接口（frontend）
  input      [31:0]  req_addr,      // 16B 块基址（S_RUN 时每拍可变）
  input              req_valid,     // frontend 有取指需求
  input              redirect,      // 后端重定向：清待发预取（错路径不发）
  output             resp_valid,    // 结果就绪（hit 或 refill/uc 完成拍，组合）
  output [127:0]     resp_line,     // 整行 4 条指令（resp_valid 同拍有效，组合）
  output             ic_busy,       // refill/uc/wait 进行中（frontend 冻结 pc）
  // 下游 AXI（到 axi_arbiter 的 IF 客户端口）
  output reg         mem_arvalid,
  input              mem_arready,
  output reg [31:0]  mem_araddr,
  output     [3:0]   mem_arlen,     // 需求 miss=7（双行）/预取=3 /uc=3
  input              mem_rvalid,
  input      [31:0]  mem_rdata,
  input              mem_rlast
);

  // ---------------- BRAM 阵列（2 路） ----------------
  (* ram_style = "block" *) reg [127:0] data_ram0 [0:511];
  (* ram_style = "block" *) reg [127:0] data_ram1 [0:511];
  (* ram_style = "block" *) reg [19:0]  tag_ram0  [0:511];   // {valid, tag[18:0]}
  (* ram_style = "block" *) reg [19:0]  tag_ram1  [0:511];
  // 伪 LRU：每组 1bit 下次替换路（寄存器数组异步读；复位 0 = 先填 way0）
  reg victim [0:511];

  // ---------------- 状态 ----------------
  localparam S_RUN    = 2'd0;   // 正常流水：每拍 req→resp（bg_fill 期间照常 hit）
  localparam S_REFILL = 2'd1;   // 需求行 refill（cached 区，beat0-3）
  localparam S_UC     = 2'd2;   // uncached 透传
  localparam S_WAIT   = 2'd3;   // bg_fill 期间来了新 miss/uc：等 rlast 再发起

  reg [1:0]   state;
  reg [31:0]  miss_addr;        // 锁存的 miss 块基址（预取时为 pf_addr）
  reg         refill_way;       // miss/pf 锁存拍采样的 victim 路
  reg [2:0]   beat;             // 需求行收数计数 0..3（S_REFILL/S_UC）
  reg         ar_sent;
  reg         dual;             // 本 refill 是双行（需求 miss 且下一行 cached）
  reg [95:0]  line_buf;         // 需求行前 3 个 beat；末 beat 直接组合进 resp
  reg [31:0]  pf2_addr;         // 后台行基址（miss_addr+16，beat3 拍锁存——必须
                                // 锁存：bg 窗口内新 miss 会改写 miss_addr，组合
                                // 引用会把 2/3/4 行数据写到错位地址）
  reg [95:0]  pf2_buf;          // 后台行（第 2/3/4 行逐行复用）前 3 个 beat
  reg         bg_fill;          // 后台填第 2-4 行进行中（beat4-15，state 已回 S_RUN）
  reg [3:0]   pfb;              // 后台收数独立计数 0..11（与 beat 解耦，防两路写错位）
  reg         wait_uc;          // S_WAIT 等的是 uc（1）还是 cached miss（0）
  reg         recheck;          // v2.8：S_WAIT 出口复查拍——miss 行可能已被 bg_fill 写入
  reg         pf;               // 当前 S_REFILL 是预取（不 resp）
  reg         pf_pending;       // 有待发预取
  reg [31:0]  pf_addr;          // 预取行基址（16B 对齐）

  // ---------------- req 侧 ----------------
  wire        req_cached = (req_addr[31:24] == 8'h1c) || (req_addr[31:28] == 4'h0);
  // pf_win（预取查 tag 窗口）assign 在 req_v_d 声明之后（iverilog 顺序限制）
  wire        pf_win;
  // recheck 拍占用读口复查 miss_addr（优先级最高：此刻前端被 ic_busy 挡住）
  wire [8:0]  rd_idx   = recheck ? miss_addr[12:4]
                       : pf_win ? pf_addr[12:4] : req_addr[12:4];
  // S_RUN 且 req_valid：BRAM 读使能（组合同拍给地址，下一拍数据有效）；
  // pf_win 拍复用读口读 pf_addr 的两路 tag（预取查重）
  wire        rd_en    = ((state == S_RUN) && req_valid && req_cached) || pf_win || recheck;

  // ---------------- BRAM 同步读/写（两路同读，写按 refill_way 选） ----------------
  reg  [127:0] data0_d, data1_d;
  reg  [19:0]  tag0_d,  tag1_d;
  // wr_en 组合 = 需求行末 beat（beat3）同拍写（run_soc13 实证：wr_en 打拍到
  // 下一拍执行时，mem_rdata 已被新总线相位覆盖，word3 错写成 0x0000aaaa）
  wire         wr_en   = (state == S_REFILL) && ar_sent && mem_rvalid && (beat == 3'd3);
  wire [8:0]   wr_idx  = miss_addr[12:4];
  wire [127:0] fill_line = {mem_rdata, line_buf};   // 需求行末 beat 组装
  // v2.8 四行 refill：bg_fill 期间每 4 beat（pfb[1:0]==3，即 beat7/11/15）齐一行，
  // 同拍写 BRAM。waddr2 按 pfb[3:2] 选第 2/3/4 行地址；pf2_buf 逐行复用
  // （每行前 3 beat 收集，第 4 beat 与 mem_rdata 组行）。同组防覆盖靠 victim
  // 时序：相邻行写相隔 4 拍，前写已刷新 victim；wr_idx 特判保需求行。
  wire         wr_en2  = bg_fill && mem_rvalid && (pfb[1:0] == 2'd3);
  wire [31:0]  waddr2  = pf2_addr + {26'd0, pfb[3:2], 4'b0000};
  wire [8:0]   pf2_idx = waddr2[12:4];
  wire         pf2_way = (pf2_idx == wr_idx) ? ~refill_way : victim[pf2_idx];
  wire [127:0] fill_line2 = {mem_rdata, pf2_buf};

  integer k;
  initial begin
    for (k = 0; k < 512; k = k + 1) begin
      tag_ram0[k]  = 20'd0;
      tag_ram1[k]  = 20'd0;
      data_ram0[k] = 128'd0;
      data_ram1[k] = 128'd0;
      victim[k]    = 1'b0;
    end
  end

  always @(posedge clk) begin
    if (rd_en) begin
      data0_d <= data_ram0[rd_idx];
      data1_d <= data_ram1[rd_idx];
      tag0_d  <= tag_ram0[rd_idx];
      tag1_d  <= tag_ram1[rd_idx];
    end
    if (wr_en) begin
      if (refill_way == 1'b0) begin
        data_ram0[wr_idx] <= fill_line;
        tag_ram0[wr_idx]  <= {1'b1, miss_addr[31:13]};
      end else begin
        data_ram1[wr_idx] <= fill_line;
        tag_ram1[wr_idx]  <= {1'b1, miss_addr[31:13]};
      end
      victim[wr_idx] <= ~refill_way;      // 下次替换另一路
    end else if (wr_en2) begin
      if (pf2_way == 1'b0) begin
        data_ram0[pf2_idx] <= fill_line2;
        tag_ram0[pf2_idx]  <= {1'b1, waddr2[31:13]};
      end else begin
        data_ram1[pf2_idx] <= fill_line2;
        tag_ram1[pf2_idx]  <= {1'b1, waddr2[31:13]};
      end
      victim[pf2_idx] <= ~pf2_way;
    end
  end

  // ---------------- hit 判定（组合，resp 拍，两路并行） ----------------
  // req_d：上一拍 req 的地址（比较 tag 用）
  reg [31:0] req_addr_d;
  reg        req_v_d;
  reg        req_cached_d;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_addr_d   <= 32'd0;
      req_v_d      <= 1'b0;
      req_cached_d <= 1'b0;
    end else if (state == S_RUN) begin
      if (recheck) begin
        req_addr_d   <= miss_addr;    // 复查：重放 S_WAIT 前锁存的 miss 地址
        req_v_d      <= 1'b1;
        req_cached_d <= 1'b1;
      end else begin
        req_addr_d   <= req_addr;
        req_v_d      <= req_valid;
        req_cached_d <= req_cached;
      end
    end else begin
      req_v_d      <= 1'b0;   // refill/uc/wait 期间清 0：防回 S_RUN 首拍陈旧 data_d 假 resp
    end
  end

  wire tag0_hit = tag0_d[19] && (tag0_d[18:0] == req_addr_d[31:13]);
  wire tag1_hit = tag1_d[19] && (tag1_d[18:0] == req_addr_d[31:13]);
  wire tag_hit  = tag0_hit || tag1_hit;

  // recheck 拍对外 busy：挡住前端 req，保证复查读口独占且不丢 req
  assign ic_busy = (state != S_RUN) || recheck;

  // 预取查 tag 窗口：完全空闲拍（无 resp 判定、无 req）复用读口读 pf_addr
  // 的两路 tag。!req_v_d 避免与 resp 拍同拍（resp_hit 会刷新 pf_addr，查
  // 旧地址无意义；需求 miss/uc 拍状态机要进 refill）
  assign pf_win = (state == S_RUN) && pf_pending && !req_valid && !req_v_d;
  reg  pf_look_d;   // 上一拍是 pf_win：本拍 tag_d 有效，判定是否发起
  wire pf_tag_hit = (tag0_d[19] && (tag0_d[18:0] == pf_addr[31:13]))
                 || (tag1_d[19] && (tag1_d[18:0] == pf_addr[31:13]));

  // ---------------- 预取触发：resp hit 拍锁存下一行 ----------------
  wire        resp_hit = (state == S_RUN) && req_v_d && req_cached_d && tag_hit;
  wire [31:0] nxt_blk  = req_addr_d + 32'd16;   // req_addr_d 已 16B 对齐
  wire [31:0] addr_p63 = req_addr_d + 32'd63;   // v2.8：四行 refill 末字节地址

  // v2.8：删除 pf2_early 提前 resp——四行 refill 下 rlast 在 beat15，
  // 此时 pf2_buf/mem_rdata 装的是第 4 行，提前 resp 会错数据。统一改由
  // S_WAIT 出口 recheck 复查（第 2/3/4 行此时已写 BRAM，命中即正常 resp）。

  // ---------------- resp 组合输出（1 拍延迟） ----------------
  // hit：req 拍 N → BRAM 拍 N+1 两路数据有效 → 组合判 tag + 2:1 MUX 同拍 resp；
  // refill/uc：需求行末 beat 同拍 resp（省 1 拍）；预取 refill 不 resp（!pf）
  wire refill_done = ((state == S_REFILL) && !pf && (beat == 3'd3)
                    || (state == S_UC) && mem_rlast)
                   && ar_sent && mem_rvalid;
  assign resp_valid = ((state == S_RUN) && req_v_d && req_cached_d && tag_hit)
                    || refill_done;
  assign resp_line  = (state == S_RUN) ? (tag0_hit ? data0_d : data1_d)
                                       : {mem_rdata, line_buf};

  // ---------------- 主状态机 ----------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_RUN;
      miss_addr   <= 32'd0;
      refill_way  <= 1'b0;
      beat        <= 3'd0;
      ar_sent     <= 1'b0;
      dual        <= 1'b0;
      pf2_addr    <= 32'd0;
      line_buf    <= 96'd0;
      pf2_buf     <= 96'd0;
      bg_fill     <= 1'b0;
      pfb         <= 4'd0;
      recheck     <= 1'b0;
      wait_uc     <= 1'b0;
      mem_arvalid <= 1'b0;
      mem_araddr  <= 32'd0;
      pf          <= 1'b0;
      pf_pending  <= 1'b0;
      pf_addr     <= 32'd0;
      pf_look_d   <= 1'b0;
    end else begin
      // -------- 伪 LRU：hit 拍把 victim 拨向另一路 --------
      if (resp_hit)
        victim[req_addr_d[12:4]] <= tag0_hit ? 1'b1 : 1'b0;

      // -------- 预取触发：resp hit 拍登记下一行（cached 才登记） --------
      if (resp_hit && ((nxt_blk[31:24] == 8'h1c) || (nxt_blk[31:28] == 4'h0))) begin
        pf_pending <= 1'b1;
        pf_addr    <= nxt_blk;
      end
      // -------- redirect：撤销待发预取（错路径不发；在途的 AXI 不可断，
      //          填完无害——写正确数据，代价仅一次组占用） --------
      if (redirect) pf_pending <= 1'b0;

      pf_look_d <= pf_win;      // 查 tag 打拍：次拍 tag_d 有效
      recheck   <= 1'b0;        // 单拍脉冲：仅 S_WAIT 出口置位

      // -------- 后台收第 2/3/4 行 beat4-15（独立 pfb 计数，与 beat 解耦） --------
      // 每行第 4 条（pfb[1:0]==3）不进 buf：同拍组合进 fill_line2 写 BRAM
      if (bg_fill && mem_rvalid && (pfb[1:0] != 2'd3))
        pf2_buf[pfb[1:0]*32 +: 32] <= mem_rdata;
      if (bg_fill && mem_rvalid) pfb <= pfb + 4'd1;
      if (bg_fill && mem_rvalid && mem_rlast) bg_fill <= 1'b0;

      case (state)
        // -------- 正常流水：resp 组合输出；miss 锁存进 refill --------
        //   优先级：需求 miss > 需求 uc > 预取（查 tag 通过且仍无需求才发）
        //   bg_fill 期间：hit/提前 resp 照服务；新 miss/uc 进 S_WAIT 等 rlast
        //   （AXI 单 outstanding，地址相位不可重叠），等待参数本拍已锁存好，
        //   S_WAIT 出口直转 S_REFILL/S_UC 即可发 AR
        S_RUN: begin
          if (req_v_d && req_cached_d && !tag_hit) begin
            miss_addr  <= req_addr_d;      // miss：锁存地址+victim 路
            refill_way <= victim[req_addr_d[12:4]];
            // v2.8 四行 refill 前提：+63B 内全是 cached 区（防越区误取 MMIO）
            dual       <= ((req_addr_d[31:24] == 8'h1c) && (addr_p63[31:24] == 8'h1c))
                       || ((req_addr_d[31:28] == 4'h0)  && (addr_p63[31:28] == 4'h0));
            beat       <= 3'd0;
            ar_sent    <= 1'b0;
            pf         <= 1'b0;
            wait_uc    <= 1'b0;
            state      <= (bg_fill && !(mem_rvalid && mem_rlast)) ? S_WAIT : S_REFILL;
          end else if (req_v_d && !req_cached_d) begin
            miss_addr <= req_addr_d;       // uncached：透传 4 beat（单行，arlen=3）
            dual      <= 1'b0;
            beat      <= 3'd0;
            ar_sent   <= 1'b0;
            wait_uc   <= 1'b1;
            state     <= (bg_fill && !(mem_rvalid && mem_rlast)) ? S_WAIT : S_UC;
          end else if (pf_look_d && pf_pending && pf_tag_hit) begin
            pf_pending <= 1'b0;            // 行已在 cache：放弃，省一次 burst
          end else if (pf_look_d && pf_pending && !req_valid && !bg_fill) begin
            miss_addr  <= pf_addr;         // 预取：查重通过且空闲，发起（单行）；
            refill_way <= victim[pf_addr[12:4]];        // !bg_fill：总线占用中不发
            dual       <= 1'b0;
            beat       <= 3'd0;
            ar_sent    <= 1'b0;
            pf         <= 1'b1;
            pf_pending <= 1'b0;
            state      <= S_REFILL;
          end
          // pf_look_d && !pf_tag_hit && req_valid：需求到来，pending 保持
          // 等下一空闲窗口重新查 tag（pf_look_d 随 pf_win 重新置位）
        end

        // -------- cached refill：burst 收需求行 beat0-3，beat3 同拍组合
        //          wr_en 写 BRAM + refill_done resp。双行：beat3 拍立即回
        //          S_RUN + bg_fill=1（beat4-7 后台收）；单行 beat3==rlast 直接回
        S_REFILL: begin
          if (!ar_sent) begin
            mem_araddr <= miss_addr;
            if (!mem_arvalid) begin
              mem_arvalid <= 1'b1;
            end else if (mem_arready) begin
              mem_arvalid <= 1'b0;
              ar_sent     <= 1'b1;
            end
          end else if (mem_rvalid) begin
            if (beat == 3'd3) begin
              // 需求行齐：写/resp 由组合逻辑同拍完成；锁存后台行基址
              pf2_addr <= miss_addr + 32'd16;
              state    <= S_RUN;
              if (dual) begin
                bg_fill <= 1'b1;           // 后台收 beat4-15（rlast 拍清）
                pfb     <= 4'd0;
              end else begin
                pf      <= 1'b0;           // 预取/单行 refill 结束
              end
            end else begin
              line_buf[beat[1:0]*32 +: 32] <= mem_rdata;
              beat <= beat + 3'd1;
            end
          end
        end

        // -------- uncached 透传：4 beat 组行直接 resp，不分配 --------
        S_UC: begin
          if (!ar_sent) begin
            mem_araddr <= miss_addr;
            if (!mem_arvalid) begin
              mem_arvalid <= 1'b1;
            end else if (mem_arready) begin
              mem_arvalid <= 1'b0;
              ar_sent     <= 1'b1;
            end
          end else if (mem_rvalid) begin
            if (mem_rlast) begin
              state <= S_RUN;
            end else begin
              line_buf[beat[1:0]*32 +: 32] <= mem_rdata;
              beat <= beat + 3'd1;
            end
          end
        end

        // -------- bg_fill 期间来了新需求：等 rlast。等待参数（miss_addr/
        //          refill_way/dual/wait_uc/ar_sent=0）进 S_WAIT 前已锁存。
        //          rlast 拍：req 的正是第二行 → 组合 pf2_early_wait 同拍
        //          resp 回 S_RUN；否则转 S_REFILL/S_UC 发 AR。beat 清 0 防御。
        S_WAIT: begin
          if (mem_rvalid && mem_rlast) begin
            bg_fill <= 1'b0;
            beat    <= 3'd0;
            // v2.8：cached miss 一律回 S_RUN 复查 tag（bg_fill 已把第 2/3/4
            // 行写进 BRAM）；命中即省一次 burst，未命中走常规 miss 重发
            state   <= wait_uc ? S_UC : S_RUN;
            recheck <= !wait_uc;
          end
        end

        default: state <= S_RUN;
      endcase
    end
  end

  // v2.8 需求四行=15 / 预取与 uc=3；AR 在 !ar_sent 窗口发出，dual 早已锁存
  assign mem_arlen = dual ? 4'd15 : 4'd3;

endmodule
