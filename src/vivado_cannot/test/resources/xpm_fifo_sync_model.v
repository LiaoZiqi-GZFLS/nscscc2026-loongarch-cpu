// [stage1 test-only] xpm_fifo_sync 行为模型,仅供 SpinalSim/Verilator 仿真。
// 覆盖本设计用到的参数子集:READ_MODE="std"、FIFO_READ_LATENCY=1、等宽读写。
// 勿用于综合(Vivado 流程使用真正的 XPM 原语)。
module xpm_fifo_sync #(
  parameter DOUT_RESET_VALUE = "0",
  parameter ECC_MODE = "no_ecc",
  parameter FIFO_MEMORY_TYPE = "auto",
  parameter integer FIFO_READ_LATENCY = 1,
  parameter integer FIFO_WRITE_DEPTH = 2048,
  parameter integer FULL_RESET_VALUE = 0,
  parameter integer PROG_EMPTY_THRESH = 10,
  parameter integer PROG_FULL_THRESH = 10,
  parameter integer RD_DATA_COUNT_WIDTH = 1,
  parameter integer READ_DATA_WIDTH = 32,
  parameter READ_MODE = "std",
  parameter integer SIM_ASSERT_CHK = 0,
  parameter USE_ADV_FEATURES = "0707",
  parameter integer WAKEUP_TIME = 0,
  parameter integer WRITE_DATA_WIDTH = 32,
  parameter integer WR_DATA_COUNT_WIDTH = 1
) (
  input  wire wr_clk,
  input  wire rst,
  output wire almost_empty,
  output wire almost_full,
  output wire empty,
  output wire full,
  output wire prog_empty,
  output wire prog_full,
  output reg  underflow,
  output reg  overflow,
  output reg  data_valid,
  output reg  [READ_DATA_WIDTH-1:0] dout,
  input  wire injectsbiterr,
  input  wire injectdbiterr,
  input  wire sleep,
  output wire sbiterr,
  output wire dbiterr,
  output reg  rd_rst_busy,
  output reg  wr_rst_busy,
  input  wire rd_en,
  input  wire wr_en,
  output reg  wr_ack,
  input  wire [WRITE_DATA_WIDTH-1:0] din,
  output wire [RD_DATA_COUNT_WIDTH-1:0] rd_data_count,
  output wire [WR_DATA_COUNT_WIDTH-1:0] wr_data_count
);
  localparam integer AW = $clog2(FIFO_WRITE_DEPTH);

  reg [WRITE_DATA_WIDTH-1:0] mem [0:FIFO_WRITE_DEPTH-1];
  reg [AW-1:0] wr_ptr, rd_ptr;
  reg [AW:0]   count;

  assign empty = (count == 0);
  assign full  = (count == FIFO_WRITE_DEPTH);
  assign almost_empty = (count <= 1);
  assign almost_full  = (count >= FIFO_WRITE_DEPTH-1);
  assign prog_empty   = (count <= PROG_EMPTY_THRESH);
  assign prog_full    = (count >= FIFO_WRITE_DEPTH - PROG_FULL_THRESH);
  assign sbiterr = 1'b0;
  assign dbiterr = 1'b0;
  assign rd_data_count = count[RD_DATA_COUNT_WIDTH-1:0];
  assign wr_data_count = count[WR_DATA_COUNT_WIDTH-1:0];

  wire do_wr = wr_en && !full && !wr_rst_busy;
  wire do_rd = rd_en && !empty && !rd_rst_busy;

  always @(posedge wr_clk) begin
    if (rst) begin
      wr_ptr <= {AW{1'b0}};
      rd_ptr <= {AW{1'b0}};
      count  <= {(AW+1){1'b0}};
      dout   <= {READ_DATA_WIDTH{1'b0}};
      data_valid <= 1'b0;
      wr_ack <= 1'b0;
      overflow <= 1'b0;
      underflow <= 1'b0;
      wr_rst_busy <= 1'b1;
      rd_rst_busy <= 1'b1;
    end else begin
      // 复位释放后 busy 再保持 1 拍
      wr_rst_busy <= 1'b0;
      rd_rst_busy <= rd_rst_busy && wr_rst_busy;
      data_valid <= do_rd;
      wr_ack <= do_wr;
      if (wr_en && full) overflow <= 1'b1;
      if (rd_en && empty) underflow <= 1'b1;
      if (do_wr) begin
        mem[wr_ptr] <= din;
        wr_ptr <= wr_ptr + 1'b1;
      end
      if (do_rd) begin
        dout <= mem[rd_ptr];
        rd_ptr <= rd_ptr + 1'b1;
      end
      case ({do_wr, do_rd})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: count <= count;
      endcase
    end
  end
endmodule
