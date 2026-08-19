// Generator : SpinalHDL v1.8.1    git head : 2a7592004363e5b40ec43e1f122ed8641cd8965b
// Component : DiscreteSkeleton
// Git hash  : 9d65dd1c8c7267f4a70bd79cd4bfd31e7d25fae6
// Date      : 19/08/2026, 12:23:53

`timescale 1ns/1ps

module DiscreteSkeleton (
  output              io_commitMailboxValid,
  output     [1:0]    io_commitMailboxPopCount,
  input               io_flushIn,
  output              io_issueGrantValid,
  output     [2:0]    io_issueGrantCell,
  input               clk,
  input               reset
);

  reg                 flushDly;

  assign io_commitMailboxValid = flushDly;
  assign io_commitMailboxPopCount = 2'b00;
  assign io_issueGrantValid = 1'b0;
  assign io_issueGrantCell = 3'b000;
  always @(posedge clk or posedge reset) begin
    if(reset) begin
      flushDly <= 1'b0;
    end else begin
      flushDly <= io_flushIn;
    end
  end


endmodule
