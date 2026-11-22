import io
tb = r"D:\code\Vivado\Loongarch_workspace\local_ci\mycpu_tb_patched.sv"
s = open(tb, encoding="utf-8", errors="replace").read()
P = "u_soc_top.u_cpu.u_nop_core.toplevel_cpu."
# add tailPtr probes for q1/q2
anchor = 'wire [3:0] dbg_q1_popc = '
assert anchor in s
new = """wire [3:0]  dbg_q1_tail = """ + P + """ROBFIFOPlugin_completionQueues_1_tailPtr;
wire [3:0]  dbg_q2_tail = """ + P + """ROBFIFOPlugin_completionQueues_2_tailPtr;
wire [3:0]  dbg_q1_hptr = """ + P + """ROBFIFOPlugin_completionQueues_1_headPtr;
wire [3:0]  dbg_q2_hptr = """ + P + """ROBFIFOPlugin_completionQueues_2_headPtr;
wire        dbg_q1_pushv = """ + P + """ROBFIFOPlugin_completionQueues_1_io_push_valid;
wire        dbg_q2_pushv = """ + P + """ROBFIFOPlugin_completionQueues_2_io_push_valid;
wire [4:0]  dbg_q1_pushridx = """ + P + """ROBFIFOPlugin_completionQueues_1_io_push_robIdx;
wire [4:0]  dbg_q2_pushridx = """ + P + """ROBFIFOPlugin_completionQueues_2_io_push_robIdx;
wire [3:0] dbg_q1_popc = """
s = s.replace(anchor, new, 1)
# switch display to negedge for settled sampling
s = s.replace("always @(posedge cpu_clk) begin\n  if ($time >= 183000", "always @(negedge cpu_clk) begin\n  if ($time >= 185300")
s = s.replace("$time <= 189000", "$time <= 186300")
old = '$display("   q0 m=%04x h=%0d pc=%0d | q1 m=%04x h=%0d pc=%0d | q2 m=%04x h=%0d pc=%0d | q3 m=%04x h=%0d pc=%0d | q4 m=%04x h=%0d pc=%0d | q5 m=%04x h=%0d pc=%0d | q6 m=%04x h=%0d pc=%0d | q7 m=%04x h=%0d pc=%0d",'
new = old + '\n      $display("   qh: q1 h=%0d t=%0d pushv=%0b pridx=%0d | q2 h=%0d t=%0d pushv=%0b pridx=%0d",\n               dbg_q1_hptr, dbg_q1_tail, dbg_q1_pushv, dbg_q1_pushridx,\n               dbg_q2_hptr, dbg_q2_tail, dbg_q2_pushv, dbg_q2_pushridx);'
assert old in s
s = s.replace(old, new, 1)
open(tb, "w", encoding="utf-8", newline="\n").write(s)
print("TB patched v8")
