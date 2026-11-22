import io
tb = r"D:\code\Vivado\Loongarch_workspace\local_ci\mycpu_tb_patched.sv"
s = open(tb, encoding="utf-8", errors="replace").read()
P = "u_soc_top.u_cpu.u_nop_core.toplevel_cpu."
anchor = 'wire [4:0]  dbg_q1_pushridx = '
assert anchor in s
new = """wire [4:0]  dbg_q0_pushridx = """ + P + """ROBFIFOPlugin_completionQueues_0_io_push_payload_robIdx;
wire        dbg_q0_pushv = """ + P + """ROBFIFOPlugin_completionQueues_0_io_push_valid;
wire [4:0]  dbg_q3_pushridx = """ + P + """ROBFIFOPlugin_completionQueues_3_io_push_payload_robIdx;
wire        dbg_q3_pushv = """ + P + """ROBFIFOPlugin_completionQueues_3_io_push_valid;
wire [4:0]  dbg_q4_pushridx = """ + P + """ROBFIFOPlugin_completionQueues_4_io_push_payload_robIdx;
wire        dbg_q4_pushv = """ + P + """ROBFIFOPlugin_completionQueues_4_io_push_valid;
wire [4:0]  dbg_q5_pushridx = """ + P + """ROBFIFOPlugin_completionQueues_5_io_push_payload_robIdx;
wire        dbg_q5_pushv = """ + P + """ROBFIFOPlugin_completionQueues_5_io_push_valid;
wire [4:0]  dbg_q6_pushridx = """ + P + """ROBFIFOPlugin_completionQueues_6_io_push_payload_robIdx;
wire        dbg_q6_pushv = """ + P + """ROBFIFOPlugin_completionQueues_6_io_push_valid;
wire [4:0]  dbg_q7_pushridx = """ + P + """ROBFIFOPlugin_completionQueues_7_io_push_payload_robIdx;
wire        dbg_q7_pushv = """ + P + """ROBFIFOPlugin_completionQueues_7_io_push_valid;
wire        dbg_p2_isb = """ + P + """ROBFIFOPlugin_debug_fifoIO_pop_2_payload_info_uop_isBranch;
wire        dbg_p2_isj = """ + P + """ROBFIFOPlugin_debug_fifoIO_pop_2_payload_info_uop_isJump;
wire        dbg_p2_isl = """ + P + """ROBFIFOPlugin_debug_fifoIO_pop_2_payload_info_uop_isLoad;
wire        dbg_p2_iss = """ + P + """ROBFIFOPlugin_debug_fifoIO_pop_2_payload_info_uop_isStore;
wire [4:0]  dbg_q1_pushridx = """
s = s.replace(anchor, new, 1)
old = '''      $display("   qh: q1 pushv=%0b pridx=%0d | q2 pushv=%0b pridx=%0d",
               dbg_q1_pushv, dbg_q1_pushridx,
               dbg_q2_pushv, dbg_q2_pushridx);'''
new = old + '''
      $display("   qh2: q0 v=%0b r=%0d | q3 v=%0b r=%0d | q4 v=%0b r=%0d | q5 v=%0b r=%0d | q6 v=%0b r=%0d | q7 v=%0b r=%0d | p2 b/j/l/s=%0b%0b%0b%0b",
               dbg_q0_pushv, dbg_q0_pushridx, dbg_q3_pushv, dbg_q3_pushridx, dbg_q4_pushv, dbg_q4_pushridx,
               dbg_q5_pushv, dbg_q5_pushridx, dbg_q6_pushv, dbg_q6_pushridx, dbg_q7_pushv, dbg_q7_pushridx,
               dbg_p2_isb, dbg_p2_isj, dbg_p2_isl, dbg_p2_iss);'''
assert old in s
s = s.replace(old, new, 1)
s = s.replace("$time >= 6500 && $time <= 10000000", "$time >= 188180 && $time <= 188400")
open(tb, "w", encoding="utf-8", newline="\n").write(s)
print("TB patched v11")
