// ============================================================================
// freelist.v — 环形空闲物理寄存器表（64 项 x 6bit，指针自然回绕）
//   复位后内含物理号 32..63（0..31 为初始架构映射，永不在表中）。
//   分配从 head 顺序取；提交释放的旧物理号压 tail。
//   分支误预测 / 例外恢复：只回滚 head（误路径分配是连续从 head 取的，O(1)）。
//   不变式：ring[head..tail) = 当前未被 fRAT 映射的物理号集合（元素可乱序）。
// ============================================================================
`include "la32_defs.vh"

module freelist(
  input        clk,
  input        rst_n,
  input  [1:0] alloc,           // 本拍分配数 0/1/2
  output [5:0] new_pd0,
  output [5:0] new_pd1,
  output       empty0,          // 一个空闲项都无
  output       empty1,          // 不足 2 个空闲项
  input  [1:0] free,            // 本拍提交释放数 0/1/2
  input  [5:0] free_pd0,
  input  [5:0] free_pd1,
  input        rollback,        // 分支/例外恢复：head 回滚到绝对值
  input  [5:0] rollback_head,
  output [5:0] head_ptr         // 供 rename 存 checkpoint / 例外回滚计算
);

  reg  [5:0] ring [0:63];
  reg  [5:0] head;
  reg  [5:0] tail;
  reg  [6:0] count;             // 0..32（任一时刻恰有 32 项被 fRAT 映射）

  // 回滚后的项数 = (tail + 同拍释放数) - rollback_head，mod 64 回绕安全
  reg  [5:0] rb_cnt;
  always @* rb_cnt = tail + {4'd0, free} - rollback_head;

  // 索引显式 6bit 截断：head/tail=63 时 +1 必须回绕到 0。
  // 直接写 ring[head + 6'd1] 在 iverilog 中按未截断的 64 索引越界
  // （读→X、写→静默丢弃），与综合语义不一致（func_test 实证 X 种子）。
  wire [5:0] head1 = head + 6'd1;
  wire [5:0] tail1 = tail + 6'd1;

  assign new_pd0  = ring[head];
  assign new_pd1  = ring[head1];
  assign empty0   = (count == 7'd0);
  assign empty1   = (count <  7'd2);
  assign head_ptr = head;

  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < 64; i = i + 1)
        ring[i] <= (i < 32) ? (i[5:0] + 6'd32) : 6'd0;
      head  <= 6'd0;
      tail  <= 6'd32;
      count <= 7'd32;
    end else if (rollback) begin
      // 回滚只动 head；同拍提交的旧物理号照常压 tail
      if (free >= 2'd1) ring[tail]          <= free_pd0;
      if (free >= 2'd2) ring[tail1]         <= free_pd1;
      head  <= rollback_head;
      tail  <= tail + {4'd0, free};
      count <= {1'b0, rb_cnt};
    end else begin
      if (free >= 2'd1) ring[tail]          <= free_pd0;
      if (free >= 2'd2) ring[tail1]         <= free_pd1;
      head  <= head + {4'd0, alloc};
      tail  <= tail + {4'd0, free};
      count <= count + {5'd0, free} - {5'd0, alloc};
    end
  end

endmodule
