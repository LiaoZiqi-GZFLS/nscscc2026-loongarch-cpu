import io
tb = r"D:\code\Vivado\Loongarch_workspace\local_ci\mycpu_tb_patched.sv"
s = open(tb, encoding="utf-8", errors="replace").read()
anchor = 'wire        dbg_rready_m  = '
assert anchor in s
new = anchor + """u_soc_top.sim_ram.u_axi_ram.axi_rready_m_masked;
wire [3:0]  dbg_cpuarid   = u_soc_top.u_cpu.arid;
wire [3:0]  dbg_ramarid   = u_soc_top.ram_arid;
wire        dbg_ramarv2   = u_soc_top.ram_arvalid;
wire        dbg_ramarr2   = u_soc_top.ram_arready;
wire [3:0]  dbg_ramrid    = u_soc_top.ram_rid;
wire        dbg_ramrv2    = u_soc_top.ram_rvalid;
wire        dbg_ramrr2    = u_soc_top.ram_rready;
wire        dbg_ramrlast2 = u_soc_top.ram_rlast;
wire        dbg_a4rv      = u_soc_top.cpu_axi4_rvalid;
wire [3:0]  dbg_a4rid     = u_soc_top.cpu_axi4_rid;
wire        dbg_a4rlast   = u_soc_top.cpu_axi4_rlast;
"""
s = s.replace(anchor, new, 1)
old_disp = '''      $display("   axi4: rmask=%0b rvs=%0b pfrand=%0b rrcnt=%0d rcmp=%0d rrdym=%0b",
               dbg_rmmask, dbg_rvs, dbg_pfrand, dbg_rcount0, dbg_rcmp, dbg_rready_m);'''
new_disp = old_disp + '''
      $display("   axi5: cpuarid=%0d ramarid=%0d | ram arv=%0b arr=%0b rv=%0b rid=%0d rlast=%0b rr=%0b | a4 rv=%0b rid=%0d rlast=%0b",
               dbg_cpuarid, dbg_ramarid, dbg_ramarv2, dbg_ramarr2, dbg_ramrv2, dbg_ramrid, dbg_ramrlast2, dbg_ramrr2,
               dbg_a4rv, dbg_a4rid, dbg_a4rlast);'''
assert old_disp in s
s = s.replace(old_disp, new_disp, 1)
open(tb, "w", encoding="utf-8", newline="\n").write(s)
print("TB patched v7")
