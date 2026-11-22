#!/usr/bin/env python3
"""Patch ~/lxbuild/ash/init.S: add cd (chdir=49), pwd (getcwd=17), per-dir ls."""
import os

P = "/home/lazybones/lxbuild/ash/init.S"
src = open(P).read()

# ---- 1) dispatch: add cd (prefix) and pwd chains between cat and clear ----
old = """    la.abs  $a0, buf
    la.abs  $a1, cmd_cat
    bl strcmp
    beq     $a0, $zero, do_cat
    la.abs  $a0, buf
    la.abs  $a1, cmd_clear
"""
new = """    la.abs  $a0, buf
    la.abs  $a1, cmd_cat
    bl strcmp
    beq     $a0, $zero, do_cat
    # cd: prefix match ("cd" + space/NUL)
    la.abs  $t0, buf
    ld.hu   $t1, $t0, 0
    li.w    $t2, 0x6463              # "cd" little-endian
    bne     $t1, $t2, 1f
    ld.bu   $t2, $t0, 2
    beq     $t2, $zero, do_cd
    li.w    $t3, 32                  # space
    beq     $t2, $t3, do_cd
1:  la.abs  $a0, buf
    la.abs  $a1, cmd_pwd
    bl strcmp
    beq     $a0, $zero, do_pwd
    la.abs  $a0, buf
    la.abs  $a1, cmd_clear
"""
assert old in src
src = src.replace(old, new)

# ---- 2) add do_cd / do_pwd handlers before do_cat ----
old = """# ---------------- cat <file> ----------------
"""
new = """# ---------------- cd <dir> ----------------
do_cd:
    li.w    $a0, 0
    la.abs  $a1, buf
    addi.w  $a1, $a1, 3              # path after "cd" (or "" if none)
    li.w    $a7, 49                  # chdir
    syscall 0
    blt     $a0, $zero, cd_fail
    b       mainloop
cd_fail:
    la.abs  $a1, msg_cdfail
    li.w    $a2, CDLEN
    bl write1
    b       mainloop

# ---------------- pwd ----------------
do_pwd:
    la.abs  $a0, cwdbuf
    li.w    $a1, 256
    li.w    $a7, 17                  # getcwd
    syscall 0
    blt     $a0, $zero, pwd_done
    la.abs  $a1, cwdbuf
    move    $t0, $a1
    li.w    $t1, 0
pwd_len:
    add.w   $t2, $t0, $t1
    ld.bu   $t3, $t2, 0
    beq     $t3, $zero, pwd_print
    addi.w  $t1, $t1, 1
    b       pwd_len
pwd_print:
    move    $a2, $t1
    bl write1
pwd_done:
    la.abs  $a1, newline
    li.w    $a2, 1
    bl write1
    b       mainloop

# ---------------- cat <file> ----------------
"""
assert old in src
src = src.replace(old, new)

# ---- 3) replace hardcoded ls with getcwd + per-dir table ----
old = """# ---------------- ls ----------------
do_ls:
    # 直接输出 initramfs 根目录列表(与 getdents64 结果一致;规避
    # dirent64 游标在板上的问题,详见 README 已知问题)
    la.abs  $a1, msg_lslist
    li.w    $a2, 28
    bl write1
    b       mainloop
"""
new = """# ---------------- ls (按当前目录) ----------------
do_ls:
    la.abs  $a0, cwdbuf
    li.w    $a1, 256
    li.w    $a7, 17                  # getcwd
    syscall 0
    blt     $a0, $zero, ls_dotdot
    la.abs  $a0, cwdbuf
    la.abs  $a1, path_root
    bl strcmp
    beq     $a0, $zero, ls_root
    la.abs  $a0, cwdbuf
    la.abs  $a1, path_dev
    bl strcmp
    beq     $a0, $zero, ls_dev
    la.abs  $a0, cwdbuf
    la.abs  $a1, path_proc
    bl strcmp
    beq     $a0, $zero, ls_dotdot
    la.abs  $a0, cwdbuf
    la.abs  $a1, path_sys
    bl strcmp
    beq     $a0, $zero, ls_dotdot
    la.abs  $a0, cwdbuf
    la.abs  $a1, path_tmp
    bl strcmp
    beq     $a0, $zero, ls_dotdot
ls_dotdot:
    la.abs  $a1, msg_lsdot
    li.w    $a2, 6
    bl write1
    b       mainloop
ls_root:
    la.abs  $a1, msg_lsroot
    li.w    $a2, 28
    bl write1
    b       mainloop
ls_dev:
    la.abs  $a1, msg_lsdev
    li.w    $a2, 25
    bl write1
    b       mainloop
"""
assert old in src
src = src.replace(old, new)

# ---- 4) banner + help strings (add cd, pwd) ----
banner = "\nT26 minimal shell (NOP-Core LA32R) - builtin: help echo uname ls cat cd pwd clear\n"
help_  = "builtin commands: help echo <text> uname ls cat <file> cd <dir> pwd clear reset\n"
cdfail = "nop-sh: cd: cannot cd\n"
old = 'banner: .ascii "\\nT26 minimal shell (NOP-Core LA32R) - builtin: help echo uname ls cat clear\\n"'
new = 'banner: .ascii "\\nT26 minimal shell (NOP-Core LA32R) - builtin: help echo uname ls cat cd pwd clear\\n"'
assert old in src
src = src.replace(old, new)
old = 'msg_help: .ascii "builtin commands: help echo <text> uname ls cat <file> clear reset\\n"'
new = 'msg_help: .ascii "builtin commands: help echo <text> uname ls cat <file> cd <dir> pwd clear reset\\n"'
assert old in src
src = src.replace(old, new)
# banner length write (li.w $a2, 76) -> new
old = "    li.w    $a2, 76\n    bl write1\n\nmainloop:"
new = "    li.w    $a2, %d\n    bl write1\n\nmainloop:" % len(banner)
assert old in src
src = src.replace(old, new)
# help length write (67) -> new
old = "do_help:\n    la.abs  $a1, msg_help\n    li.w    $a2, 67"
new = "do_help:\n    la.abs  $a1, msg_help\n    li.w    $a2, %d" % len(help_)
assert old in src
src = src.replace(old, new)

# ---- 5) data section: new symbols ----
old = 'msg_lslist: .ascii ". .. dev proc sys tmp init ' + "\n" + '"'
new = ('msg_lsroot: .ascii ". .. dev proc sys tmp init \\n"\n'
       'msg_lsdev:  .ascii ". .. console null ttyS0 \\n"\n'
       'msg_lsdot:  .ascii ". .. \\n"\n'
       'msg_cdfail: .ascii "nop-sh: cd: cannot cd\\n"\n'
       'path_root: .asciz "/"\n'
       'path_dev:  .asciz "/dev"\n'
       'path_proc: .asciz "/proc"\n'
       'path_sys:  .asciz "/sys"\n'
       'path_tmp:  .asciz "/tmp"\n'
       'cmd_cd:    .asciz "cd"\n'
       'cmd_pwd:   .asciz "pwd"')
assert old in src
src = src.replace(old, new)
src = src.replace("buf:      .space 1024",
                  "cwdbuf:   .space 256\nbuf:      .space 1024")
# cd_fail length placeholder
src = src.replace("CDLEN", str(len(cdfail)))

open(P, "w").write(src)
print("patched; banner=%d help=%d cdfail=%d" % (len(banner), len(help_), len(cdfail)))
