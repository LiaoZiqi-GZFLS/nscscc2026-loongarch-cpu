import io
tb = r"D:\code\Vivado\Loongarch_workspace\local_ci\mycpu_tb_patched.sv"
s = open(tb, encoding="utf-8", errors="replace").read()
anchor = 'wire        dbg_arnomask  = '
assert anchor in s
new = anchor + """u_soc_top.sim_ram.u_axi_ram.ar_nomask;
wire [4:0]  dbg_rmmask    = u_soc_top.sim_ram.u_axi_ram.ram_random_mask;
wire [31:0] dbg_rcount0   = u_soc_top.sim_ram.u_axi_ram.r_count[0];
wire [31:0] dbg_rcmp      = u_soc_top.sim_ram.u_axi_ram.r_countcmp;
wire        dbg_pfrand    = u_soc_top.sim_ram.u_axi_ram.pf_r_and;
wire        dbg_rvs       = u_soc_top.sim_ram.u_axi_ram.axi_rvalid_s_unmasked;
wire        dbg_rready_m  = u_soc_top.sim_ram.u_axi_ram.axi_rready_m_masked;
"""
s = s.replace(anchor, new, 1)
old_disp = '''      $display("   axi3: ram arv=%0b armask=%0b arr=%0b nomask=%0b | rv=%0b rlast=%0b pf=%0d rs0=%0d rs1=%0d",
               dbg_ramarv, dbg_ramarmask, dbg_ramarr, dbg_arnomask, dbg_ramrv, dbg_ramrlast, dbg_rampf, dbg_ramrs0, dbg_ramrs1);'''
new_disp = old_disp + '''
      $display("   axi4: rmask=%0b rvs=%0b pfrand=%0b rrcnt=%0d rcmp=%0d rrdym=%0b",
               dbg_rmmask, dbg_rvs, dbg_pfrand, dbg_rcount0, dbg_rcmp, dbg_rready_m);'''
assert old_disp in s
s = s.replace(old_disp, new_disp, 1)
open(tb, "w", encoding="utf-8", newline="\n").write(s)
print("TB patched v6")
