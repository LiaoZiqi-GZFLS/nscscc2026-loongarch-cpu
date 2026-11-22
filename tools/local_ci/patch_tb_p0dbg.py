import io
tb = r"D:\code\Vivado\Loongarch_workspace\local_ci\mycpu_tb_patched.sv"
s = open(tb, encoding="utf-8", errors="replace").read()
P = "u_soc_top.u_cpu.u_nop_core.toplevel_cpu."

block = """
// ==== P0 DBG probes (completion-queue commit) ====
wire [4:0] dbg_pushPtr = """ + P + """ROBFIFOPlugin_robInfo_pushPtr;
wire [4:0] dbg_popPtr  = """ + P + """ROBFIFOPlugin_robInfo_popPtr;
wire [1:0] dbg_popCnt  = """ + P + """ROBFIFOPlugin_robInfo_popCount;
wire       dbg_flush   = """ + P + """ROBFIFOPlugin_debug_fifoIO_flush;
"""
for i in range(3):
    block += ("wire dbg_p%d_valid = %sROBFIFOPlugin_debug_fifoIO_pop_%d_valid;\n" % (i, P, i))
    block += ("wire dbg_p%d_ready = %sROBFIFOPlugin_debug_fifoIO_pop_%d_ready;\n" % (i, P, i))
    block += ("wire dbg_p%d_cmplt = %sROBFIFOPlugin_debug_fifoIO_pop_%d_payload_state_complete;\n" % (i, P, i))
    block += ("wire dbg_p%d_excv  = %sROBFIFOPlugin_debug_fifoIO_pop_%d_payload_state_except_valid;\n" % (i, P, i))
    block += ("wire [31:0] dbg_p%d_pc = %sROBFIFOPlugin_debug_fifoIO_pop_%d_payload_info_uop_pc;\n" % (i, P, i))
for q in range(8):
    block += ("wire [15:0] dbg_q%d_mask = {%sROBFIFOPlugin_completionQueues_%d_io_window_15_valid" % (q, P, q))
    for d in range(14, -1, -1):
        block += (",%sROBFIFOPlugin_completionQueues_%d_io_window_%d_valid" % (P, q, d))
    block += "};\n"
    block += ("wire [4:0] dbg_q%d_head = %sROBFIFOPlugin_completionQueues_%d_io_window_0_robIdx;\n" % (q, P, q))
    block += ("wire [3:0] dbg_q%d_popc = %sROBFIFOPlugin_completionQueues_%d_io_popCount;\n" % (q, P, q))

block += """
reg [63:0] p0dbg_cyc = 0;
always @(posedge cpu_clk) begin
  p0dbg_cyc <= p0dbg_cyc + 64'd1;
  if ($time >= 756000 && $time <= 762500) begin
    $display("[P0DBG %t] pp=%0d op=%0d pcnt=%0d flush=%0d",
             $time, dbg_pushPtr, dbg_popPtr, dbg_popCnt, dbg_flush);
    $display("   p0 v=%0b r=%0b c=%0b e=%0b pc=%08x | p1 v=%0b r=%0b c=%0b e=%0b pc=%08x | p2 v=%0b r=%0b c=%0b e=%0b pc=%08x",
             dbg_p0_valid, dbg_p0_ready, dbg_p0_cmplt, dbg_p0_excv, dbg_p0_pc,
             dbg_p1_valid, dbg_p1_ready, dbg_p1_cmplt, dbg_p1_excv, dbg_p1_pc,
             dbg_p2_valid, dbg_p2_ready, dbg_p2_cmplt, dbg_p2_excv, dbg_p2_pc);
    $display("   q0 m=%04x h=%0d pc=%0d | q1 m=%04x h=%0d pc=%0d | q2 m=%04x h=%0d pc=%0d | q3 m=%04x h=%0d pc=%0d",
             dbg_q0_mask, dbg_q0_head, dbg_q0_popc, dbg_q1_mask, dbg_q1_head, dbg_q1_popc,
             dbg_q2_mask, dbg_q2_head, dbg_q2_popc, dbg_q3_mask, dbg_q3_head, dbg_q3_popc);
    $display("   q4 m=%04x h=%0d pc=%0d | q5 m=%04x h=%0d pc=%0d | q6 m=%04x h=%0d pc=%0d | q7 m=%04x h=%0d pc=%0d",
             dbg_q4_mask, dbg_q4_head, dbg_q4_popc, dbg_q5_mask, dbg_q5_head, dbg_q5_popc,
             dbg_q6_mask, dbg_q6_head, dbg_q6_popc, dbg_q7_mask, dbg_q7_head, dbg_q7_popc);
  end
end
"""
anchor = "//模拟串口打印"
assert anchor in s, "anchor not found"
s = s.replace(anchor, block + "\n" + anchor, 1)
open(tb, "w", encoding="utf-8", newline="\n").write(s)
print("TB patched, new size:", len(s))
