import io
tb = r"D:\code\Vivado\Loongarch_workspace\local_ci\mycpu_tb_patched.sv"
s = open(tb, encoding="utf-8", errors="replace").read()
P = "u_soc_top.u_cpu.u_nop_core.toplevel_cpu."
anchor = 'wire        dbg_darvalid = '
assert anchor in s
new = anchor + """u_soc_top.u_cpu.u_nop_core.toplevel_cpu.io_dBus_ar_valid;
wire        dbg_udarv    = """ + P + """io_udBus_ar_valid;
wire        dbg_udarr    = u_soc_top.u_cpu.u_nop_core.toplevel_crossbar_io_udBus_ar_ready;
wire        dbg_udrv     = u_soc_top.u_cpu.u_nop_core.toplevel_crossbar_io_udBus_r_valid;
wire        dbg_abarv    = u_soc_top.u_cpu.u_nop_core.toplevel_axiBuffer_io_out_axi_ar_valid;
wire        dbg_toparv   = u_soc_top.u_cpu.arvalid;
wire        dbg_toparr   = u_soc_top.u_cpu.arready;
wire        dbg_toprv    = u_soc_top.u_cpu.rvalid;
wire        dbg_toprr    = u_soc_top.u_cpu.rready;
"""
s = s.replace(anchor, new, 1)
old_disp = '''      $display("   axi: arv=%0b arr=%0b araddr=%08x | rv=%0b rid=%0d rlast=%0b | start=%0b kill=%0b exit=%0b | darv=%0b drv=%0b drr=%0b",
               dbg_farvalid, dbg_farready, dbg_faraddr, dbg_frvalid, dbg_frid, dbg_frlast,
               dbg_fstart, dbg_fkill, dbg_fexit, dbg_darvalid, dbg_drvalid, dbg_drready);'''
new_disp = old_disp + '''
      $display("   axi2: udarv=%0b udarr=%0b udrv=%0b abarv=%0b | top: arv=%0b arr=%0b rv=%0b rr=%0b",
               dbg_udarv, dbg_udarr, dbg_udrv, dbg_abarv, dbg_toparv, dbg_toparr, dbg_toprv, dbg_toprr);'''
assert old_disp in s
s = s.replace(old_disp, new_disp, 1)
open(tb, "w", encoding="utf-8", newline="\n").write(s)
print("TB patched v4")
