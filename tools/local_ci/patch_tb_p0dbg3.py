import io
tb = r"D:\code\Vivado\Loongarch_workspace\local_ci\mycpu_tb_patched.sv"
s = open(tb, encoding="utf-8", errors="replace").read()
P = "u_soc_top.u_cpu.u_nop_core.toplevel_cpu."
old = 'wire        dbg_fbpop0pc = """'.replace('"""','') # no-op guard
# insert AXI probes after the refetch line
anchor = "wire        dbg_frefetch = "
assert anchor in s
axi = """wire        dbg_frefetch = """ + P + """ICachePlugin_refetchValid;
wire        dbg_farvalid = """ + P + """ICachePlugin_iBus_ar_valid;
wire        dbg_farready = """ + P + """ICachePlugin_iBus_ar_ready;
wire [31:0] dbg_faraddr  = """ + P + """ICachePlugin_iBus_ar_payload_addr;
wire        dbg_frvalid  = """ + P + """ICachePlugin_iBus_r_valid;
wire [3:0]  dbg_frid     = """ + P + """ICachePlugin_iBus_r_payload_id;
wire        dbg_frlast   = """ + P + """ICachePlugin_iBus_r_payload_last;
wire        dbg_fstart   = """ + P + """IF3_ICachePlugin_cacheRefillFSM_wantStart;
wire        dbg_fkill    = """ + P + """IF3_ICachePlugin_cacheRefillFSM_wantKill;
wire        dbg_fexit    = """ + P + """IF3_ICachePlugin_cacheRefillFSM_wantExit;
wire        dbg_darvalid = """ + P + """io_dBus_ar_valid;
wire        dbg_drready  = """ + P + """io_dBus_r_ready;
wire        dbg_drvalid  = """ + P + """io_dBus_r_valid;
"""
s = s.replace(anchor, axi, 1)
# extend the display: add AXI line after the fetch line
old_disp = '''      $display("   fpc=%08x off=%0d req=%0b ibusr=%0b refetch=%0b insts=%0b%0b%0b%0b except=%0b fbpop=%0b%0b%0b pc=%08x %08x %08x",
               dbg_fpc, dbg_foff, dbg_freq, dbg_fibusr, dbg_frefetch,
               dbg_finst0,dbg_finst1,dbg_finst2,dbg_finst3, dbg_fexcept,
               dbg_fbpop0,dbg_fbpop1,dbg_fbpop2, dbg_fbpop0pc, dbg_fbpop1pc, dbg_fbpop2pc);'''
new_disp = old_disp + '''
      $display("   axi: arv=%0b arr=%0b araddr=%08x | rv=%0b rid=%0d rlast=%0b | start=%0b kill=%0b exit=%0b | darv=%0b drv=%0b drr=%0b",
               dbg_farvalid, dbg_farready, dbg_faraddr, dbg_frvalid, dbg_frid, dbg_frlast,
               dbg_fstart, dbg_fkill, dbg_fexit, dbg_darvalid, dbg_drvalid, dbg_drready);'''
assert old_disp in s
s = s.replace(old_disp, new_disp, 1)
open(tb, "w", encoding="utf-8", newline="\n").write(s)
print("TB patched v3")
