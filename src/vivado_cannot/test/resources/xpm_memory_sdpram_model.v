// [stage1 test-only] xpm_memory_sdpram 行为模型,仅供 SpinalSim/Verilator 仿真。
// 覆盖本设计用到的参数子集:READ_LATENCY_B ∈ {0,1,2},BYTE_WRITE_WIDTH_A 字节使能,
// WRITE_MODE_B=read_first(同沿写同地址读旧值,Verilog 非阻塞天然语义)。
// 勿用于综合(Vivado 流程使用真正的 XPM 原语)。
module xpm_memory_sdpram #(
  parameter integer ADDR_WIDTH_A = 6,
  parameter integer ADDR_WIDTH_B = 6,
  parameter integer AUTO_SLEEP_TIME = 0,
  parameter integer BYTE_WRITE_WIDTH_A = 32,
  parameter integer CASCADE_HEIGHT = 0,
  parameter CLOCKING_MODE = "common_clock",
  parameter ECC_MODE = "no_ecc",
  parameter MEMORY_INIT_FILE = "none",
  parameter MEMORY_INIT_PARAM = "0",
  parameter MEMORY_OPTIMIZATION = "true",
  parameter MEMORY_PRIMITIVE = "auto",
  parameter integer MEMORY_SIZE = 2048,
  parameter integer MESSAGE_CONTROL = 0,
  parameter integer READ_DATA_WIDTH_B = 32,
  parameter integer READ_LATENCY_B = 2,
  parameter READ_RESET_VALUE_B = "0",
  parameter RST_MODE_A = "SYNC",
  parameter RST_MODE_B = "SYNC",
  parameter integer SIM_ASSERT_CHK = 0,
  parameter integer USE_EMBEDDED_CONSTRAINT = 0,
  parameter integer USE_MEM_INIT = 0,
  parameter WAKEUP_TIME = "disable_sleep",
  parameter integer WRITE_DATA_WIDTH_A = 32,
  parameter WRITE_MODE_B = "no_change"
) (
  input  wire clka,
  input  wire ena,
  input  wire [WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-1:0] wea,
  input  wire [ADDR_WIDTH_A-1:0] addra,
  input  wire [WRITE_DATA_WIDTH_A-1:0] dina,
  input  wire injectsbiterra,
  input  wire injectdbiterra,
  input  wire clkb,
  input  wire rstb,
  input  wire enb,
  input  wire regceb,
  input  wire [ADDR_WIDTH_B-1:0] addrb,
  output reg  [READ_DATA_WIDTH_B-1:0] doutb,
  output wire sbiterrb,
  output wire dbiterrb,
  input  wire sleep
);
  localparam integer DEPTH = MEMORY_SIZE / WRITE_DATA_WIDTH_A;
  localparam integer WE_WIDTH = WRITE_DATA_WIDTH_A / BYTE_WRITE_WIDTH_A;

  reg [WRITE_DATA_WIDTH_A-1:0] mem [0:DEPTH-1];

  assign sbiterrb = 1'b0;
  assign dbiterrb = 1'b0;

  integer k;
  always @(posedge clka) begin
    if (ena) begin
      for (k = 0; k < WE_WIDTH; k = k + 1)
        if (wea[k])
          mem[addra][k*BYTE_WRITE_WIDTH_A +: BYTE_WRITE_WIDTH_A] <=
            dina[k*BYTE_WRITE_WIDTH_A +: BYTE_WRITE_WIDTH_A];
    end
  end

  generate
    if (READ_LATENCY_B == 0) begin : g_async
      always @(*) doutb = mem[addrb];
    end else if (READ_LATENCY_B == 1) begin : g_lat1
      always @(posedge clkb) begin
        if (rstb) doutb <= {READ_DATA_WIDTH_B{1'b0}};
        else if (enb) doutb <= mem[addrb];
      end
    end else begin : g_lat2
      reg [READ_DATA_WIDTH_B-1:0] stage1;
      always @(posedge clkb) begin
        if (rstb) begin
          stage1 <= {READ_DATA_WIDTH_B{1'b0}};
          doutb  <= {READ_DATA_WIDTH_B{1'b0}};
        end else begin
          if (enb) stage1 <= mem[addrb];
          if (regceb) doutb <= stage1;
        end
      end
    end
  endgenerate
endmodule
