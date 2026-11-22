import io
tb = r"D:\code\Vivado\Loongarch_workspace\local_ci\mycpu_tb_patched.sv"
s = open(tb, encoding="utf-8", errors="replace").read()
P = "u_soc_top.u_cpu.u_nop_core.toplevel_cpu."
anchor = 'wire        dbg_q1_pushv = '
assert anchor in s
new = """wire [15:0] dbg_q1_pm   = """ + P + """_zz_io_popMask_1;
wire        dbg_fire0   = """ + P + """ROBFIFOPlugin_robInfo_io_pop_0_fire;
wire        dbg_fire1   = """ + P + """ROBFIFOPlugin_robInfo_io_pop_1_fire;
wire        dbg_fire2   = """ + P + """ROBFIFOPlugin_robInfo_io_pop_2_fire;
wire [4:0]  dbg_q1_w0ridx = """ + P + """ROBFIFOPlugin_completionQueues_1_io_window_0_robIdx;
wire [4:0]  dbg_q1_w1ridx = """ + P + """ROBFIFOPlugin_completionQueues_1_io_window_1_robIdx;
wire [4:0]  dbg_q1_w2ridx = """ + P + """ROBFIFOPlugin_completionQueues_1_io_window_2_robIdx;
wire [4:0]  dbg_q1_w3ridx = """ + P + """ROBFIFOPlugin_completionQueues_1_io_window_3_robIdx;
wire        dbg_q1_pushv = """
s = s.replace(anchor, new, 1)
old = '''      $display("   qh: q1 pushv=%0b pridx=%0d | q2 pushv=%0b pridx=%0d",
               dbg_q1_pushv, dbg_q1_pushridx,
               dbg_q2_pushv, dbg_q2_pushridx);'''
new = old + '''
      $display("   q1w=%0d %0d %0d %0d pm=%04x fire=%0b%0b%0b",
               dbg_q1_w0ridx, dbg_q1_w1ridx, dbg_q1_w2ridx, dbg_q1_w3ridx,
               dbg_q1_pm, dbg_fire0, dbg_fire1, dbg_fire2);'''
assert old in s
s = s.replace(old, new, 1)
# re-window to the first retires
s = s.replace("$time >= 15000", "$time >= 3000")
s = s.replace("$time <= 45000", "$time <= 11000")
open(tb, "w", encoding="utf-8", newline="\n").write(s)
print("TB patched v10")
