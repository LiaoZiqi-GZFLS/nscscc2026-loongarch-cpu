// [stage1 test-only] multiplier 行为模型,仅供 SpinalSim/Verilator 仿真。
// 2 拍流水(对应 MyCPUConfig.mulDiv.multiplyLatency = 2)。勿用于综合。
module multiplier #(
  parameter integer WIDTH = 32
) (
  input  wire CLK,
  input  wire [WIDTH-1:0] A,
  input  wire [WIDTH-1:0] B,
  output reg  [2*WIDTH-1:0] P
);
  reg [2*WIDTH-1:0] s1;
  always @(posedge CLK) begin
    s1 <= A * B;
    P  <= s1;
  end
endmodule
