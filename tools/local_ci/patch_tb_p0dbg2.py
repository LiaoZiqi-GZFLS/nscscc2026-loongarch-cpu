import io
tb = r"D:\code\Vivado\Loongarch_workspace\local_ci\mycpu_tb_patched.sv"
s = open(tb, encoding="utf-8", errors="replace").read()
start = s.index("// ==== P0 DBG probes")
end = s.index("//模拟串口打印")
P = "u_soc_top.u_cpu.u_nop_core.toplevel_cpu."

block = """// ==== P0 DBG probes v2 (completion-queue commit + fetch) ====
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
# fetch probes
block += """wire [31:0] dbg_fpc      = """ + P + """IF3_ICachePlugin_fetchPacket_pc;
wire [3:0]  dbg_foff     = """ + P + """IF3_ICachePlugin_pcWordOffset;
wire        dbg_fibusr   = """ + P + """ICachePlugin_iBus_r_valid;
wire        dbg_freq     = """ + P + """ICachePlugin_reqValid;
wire        dbg_frefetch = """ + P + """ICachePlugin_refetchValid;
wire        dbg_finst0   = """ + P + """IF3_ICachePlugin_fetchPacket_insts_0_valid;
wire        dbg_finst1   = """ + P + """IF3_ICachePlugin_fetchPacket_insts_1_valid;
wire        dbg_finst2   = """ + P + """IF3_ICachePlugin_fetchPacket_insts_2_valid;
wire        dbg_finst3   = """ + P + """IF3_ICachePlugin_fetchPacket_insts_3_valid;
wire        dbg_fexcept  = """ + P + """IF3_ICachePlugin_fetchPacket_except_valid;
wire        dbg_fbpop0   = """ + P + """FetchBufferPlugin_bufferFIFO_io_pop_0_valid;
wire        dbg_fbpop1   = """ + P + """FetchBufferPlugin_bufferFIFO_io_pop_1_valid;
wire        dbg_fbpop2   = """ + P + """FetchBufferPlugin_bufferFIFO_io_pop_2_valid;
wire [31:0] dbg_fbpop0pc = """ + P + """FetchBufferPlugin_bufferFIFO_io_pop_0_payload_pc;
wire [31:0] dbg_fbpop1pc = """ + P + """FetchBufferPlugin_bufferFIFO_io_pop_1_payload_pc;
wire [31:0] dbg_fbpop2pc = """ + P + """FetchBufferPlugin_bufferFIFO_io_pop_2_payload_pc;

reg [31:0]  p0dbg_last_sig = 0;
always @(posedge cpu_clk) begin
  if ($time >= 756000 && $time <= 759500) begin
    // 只在状态变化时打印(压缩日志)
    if ({dbg_pushPtr,dbg_popPtr,dbg_popCnt,dbg_flush,dbg_p0_valid,dbg_p0_ready,dbg_p0_cmplt,
         dbg_p1_valid,dbg_p1_ready,dbg_p1_cmplt,dbg_p2_valid,dbg_p2_ready,dbg_p2_cmplt,
         dbg_q0_mask,dbg_q1_mask,dbg_q2_mask,dbg_q3_mask,dbg_q4_mask,dbg_q5_mask,dbg_q6_mask,dbg_q7_mask,
         dbg_fpc,dbg_foff,dbg_fibusr,dbg_freq,dbg_frefetch,dbg_finst0,dbg_finst1,dbg_finst2,dbg_finst3,
         dbg_fbpop0,dbg_fbpop1,dbg_fbpop2} != p0dbg_last_sig) begin
      p0dbg_last_sig <= {dbg_pushPtr,dbg_popPtr,dbg_popCnt,dbg_flush,dbg_p0_valid,dbg_p0_ready,dbg_p0_cmplt,
         dbg_p1_valid,dbg_p1_ready,dbg_p1_cmplt,dbg_p2_valid,dbg_p2_ready,dbg_p2_cmplt,
         dbg_q0_mask,dbg_q1_mask,dbg_q2_mask,dbg_q3_mask,dbg_q4_mask,dbg_q5_mask,dbg_q6_mask,dbg_q7_mask,
         dbg_fpc,dbg_foff,dbg_fibusr,dbg_freq,dbg_frefetch,dbg_finst0,dbg_finst1,dbg_finst2,dbg_finst3,
         dbg_fbpop0,dbg_fbpop1,dbg_fbpop2};
      $display("[P0 %t] pp=%0d op=%0d pcnt=%0d flush=%0d | p v/r/c: %0b%0b%0b %0b%0b%0b %0b%0b%0b",
               $time, dbg_pushPtr, dbg_popPtr, dbg_popCnt, dbg_flush,
               dbg_p0_valid,dbg_p0_ready,dbg_p0_cmplt, dbg_p1_valid,dbg_p1_ready,dbg_p1_cmplt,
               dbg_p2_valid,dbg_p2_ready,dbg_p2_cmplt);
      $display("   p0pc=%08x p1pc=%08x p2pc=%08x", dbg_p0_pc, dbg_p1_pc, dbg_p2_pc);
      $display("   q0 m=%04x h=%0d pc=%0d | q1 m=%04x h=%0d pc=%0d | q2 m=%04x h=%0d pc=%0d | q3 m=%04x h=%0d pc=%0d | q4 m=%04x h=%0d pc=%0d | q5 m=%04x h=%0d pc=%0d | q6 m=%04x h=%0d pc=%0d | q7 m=%04x h=%0d pc=%0d",
               dbg_q0_mask,dbg_q0_head,dbg_q0_popc, dbg_q1_mask,dbg_q1_head,dbg_q1_popc,
               dbg_q2_mask,dbg_q2_head,dbg_q2_popc, dbg_q3_mask,dbg_q3_head,dbg_q3_popc,
               dbg_q4_mask,dbg_q4_head,dbg_q4_popc, dbg_q5_mask,dbg_q5_head,dbg_q5_popc,
               dbg_q6_mask,dbg_q6_head,dbg_q6_popc, dbg_q7_mask,dbg_q7_head,dbg_q7_popc);
      $display("   fpc=%08x off=%0d req=%0b ibusr=%0b refetch=%0b insts=%0b%0b%0b%0b except=%0b fbpop=%0b%0b%0b pc=%08x %08x %08x",
               dbg_fpc, dbg_foff, dbg_freq, dbg_fibusr, dbg_frefetch,
               dbg_finst0,dbg_finst1,dbg_finst2,dbg_finst3, dbg_fexcept,
               dbg_fbpop0,dbg_fbpop1,dbg_fbpop2, dbg_fbpop0pc, dbg_fbpop1pc, dbg_fbpop2pc);
    end
  end
end
"""
s = s[:start] + block + "\n" + s[end:]
open(tb, "w", encoding="utf-8", newline="\n").write(s)
print("TB patched v2")
