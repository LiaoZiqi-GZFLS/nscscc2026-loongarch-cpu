import io
tb = r"D:\code\Vivado\Loongarch_workspace\local_ci\mycpu_tb_patched.sv"
s = open(tb, encoding="utf-8", errors="replace").read()
broken = '''      $display("   q0 m=%04x h=%0d pc=%0d | q1 m=%04x h=%0d pc=%0d | q2 m=%04x h=%0d pc=%0d | q3 m=%04x h=%0d pc=%0d | q4 m=%04x h=%0d pc=%0d | q5 m=%04x h=%0d pc=%0d | q6 m=%04x h=%0d pc=%0d | q7 m=%04x h=%0d pc=%0d",
      $display("   qh: q1 h=%0d t=%0d pushv=%0b pridx=%0d | q2 h=%0d t=%0d pushv=%0b pridx=%0d",
               dbg_q1_hptr, dbg_q1_tail, dbg_q1_pushv, dbg_q1_pushridx,
               dbg_q2_hptr, dbg_q2_tail, dbg_q2_pushv, dbg_q2_pushridx);
               dbg_q0_mask,dbg_q0_head,dbg_q0_popc, dbg_q1_mask,dbg_q1_head,dbg_q1_popc,
               dbg_q2_mask,dbg_q2_head,dbg_q2_popc, dbg_q3_mask,dbg_q3_head,dbg_q3_popc,
               dbg_q4_mask,dbg_q4_head,dbg_q4_popc, dbg_q5_mask,dbg_q5_head,dbg_q5_popc,
               dbg_q6_mask,dbg_q6_head,dbg_q6_popc, dbg_q7_mask,dbg_q7_head,dbg_q7_popc);'''
fixed = '''      $display("   q0 m=%04x h=%0d pc=%0d | q1 m=%04x h=%0d pc=%0d | q2 m=%04x h=%0d pc=%0d | q3 m=%04x h=%0d pc=%0d | q4 m=%04x h=%0d pc=%0d | q5 m=%04x h=%0d pc=%0d | q6 m=%04x h=%0d pc=%0d | q7 m=%04x h=%0d pc=%0d",
               dbg_q0_mask,dbg_q0_head,dbg_q0_popc, dbg_q1_mask,dbg_q1_head,dbg_q1_popc,
               dbg_q2_mask,dbg_q2_head,dbg_q2_popc, dbg_q3_mask,dbg_q3_head,dbg_q3_popc,
               dbg_q4_mask,dbg_q4_head,dbg_q4_popc, dbg_q5_mask,dbg_q5_head,dbg_q5_popc,
               dbg_q6_mask,dbg_q6_head,dbg_q6_popc, dbg_q7_mask,dbg_q7_head,dbg_q7_popc);
      $display("   qh: q1 h=%0d t=%0d pushv=%0b pridx=%0d | q2 h=%0d t=%0d pushv=%0b pridx=%0d",
               dbg_q1_hptr, dbg_q1_tail, dbg_q1_pushv, dbg_q1_pushridx,
               dbg_q2_hptr, dbg_q2_tail, dbg_q2_pushv, dbg_q2_pushridx);'''
assert broken in s
s = s.replace(broken, fixed, 1)
open(tb, "w", encoding="utf-8", newline="\n").write(s)
print("TB patched v9")
