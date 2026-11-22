import io
tb = r"D:\code\Vivado\Loongarch_workspace\local_ci\mycpu_tb_patched.sv"
s = open(tb, encoding="utf-8", errors="replace").read()
anchor = 'wire        dbg_toprv    = '
assert anchor in s
new = anchor + """u_soc_top.u_cpu.rvalid;
wire        dbg_ramarmask = u_soc_top.sim_ram.u_axi_ram.axi_arvalid_m_masked;
wire        dbg_ramarv    = u_soc_top.sim_ram.u_axi_ram.axi_arvalid;
wire        dbg_ramarr    = u_soc_top.sim_ram.u_axi_ram.axi_arready;
wire        dbg_ramrv     = u_soc_top.sim_ram.u_axi_ram.axi_rvalid;
wire        dbg_ramrlast  = u_soc_top.sim_ram.u_axi_ram.axi_rlast;
wire [4:0]  dbg_rampf     = u_soc_top.sim_ram.u_axi_ram.pf_r2r;
wire [2:0]  dbg_ramrs0    = u_soc_top.sim_ram.u_axi_ram.rstate[0];
wire [2:0]  dbg_ramrs1    = u_soc_top.sim_ram.u_axi_ram.rstate[1];
wire        dbg_arnomask  = u_soc_top.sim_ram.u_axi_ram.ar_nomask;
"""
s = s.replace(anchor, new, 1)
old_disp = '''      $display("   axi2: udarv=%0b udarr=%0b udrv=%0b abarv=%0b | top: arv=%0b arr=%0b rv=%0b rr=%0b",
               dbg_udarv, dbg_udarr, dbg_udrv, dbg_abarv, dbg_toparv, dbg_toparr, dbg_toprv, dbg_toprr);'''
new_disp = old_disp + '''
      $display("   axi3: ram arv=%0b armask=%0b arr=%0b nomask=%0b | rv=%0b rlast=%0b pf=%0d rs0=%0d rs1=%0d",
               dbg_ramarv, dbg_ramarmask, dbg_ramarr, dbg_arnomask, dbg_ramrv, dbg_ramrlast, dbg_rampf, dbg_ramrs0, dbg_ramrs1);'''
assert old_disp in s
s = s.replace(old_disp, new_disp, 1)
open(tb, "w", encoding="utf-8", newline="\n").write(s)
print("TB patched v5")
