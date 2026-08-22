# T26 minimal interactive shell, pure assembly, no libc.
# Builtins: help, echo, uname, ls, cat, clear, reset
# Everything else: "command not found"
# Syscall numbers (generic ABI, verified on this kernel): read=63 write=64
# openat=56 close=57 getdents64=61 uname=160

    .text
    .globl _start

# ---------------- entry ----------------
_start:
    # banner
    la.abs  $a1, banner
    li.w    $a2, 83
    bl write1

mainloop:
    # prompt
    la.abs  $a1, prompt
    li.w    $a2, 5
    bl write1
    # read(0, buf, 256)
    li.w    $a0, 0
    la.abs  $a1, buf
    li.w    $a2, 256
    li.w    $a7, 63
    syscall 0
    blt     $a0, $zero, mainloop     # -EAGAIN etc: retry
    beq     $a0, $zero, mainloop     # EOF
    move    $s0, $a0                 # s0 = input length
    la.abs  $s1, buf                 # s1 = buf pointer

    # strip trailing newline/CR
strip:
    beq     $s0, $zero, dispatch
    addi.w  $t0, $s0, -1
    add.w   $t1, $s1, $t0
    ld.bu   $t2, $t1, 0
    li.w    $t3, 10
    beq     $t2, $t3, 1f
    li.w    $t3, 13
    bne     $t2, $t3, dispatch
1:  st.b    $zero, $t1, 0
    addi.w  $s0, $s0, -1
    b       strip

dispatch:
    beq     $s0, $zero, mainloop     # empty line
    # echo back a newline first (line discipline)
    la.abs  $a1, newline
    li.w    $a2, 1
    bl write1
    # compare against builtins
    la.abs  $a0, buf
    la.abs  $a1, cmd_help
    bl strcmp
    beq     $a0, $zero, do_help
    # echo: prefix match (first 4 bytes == "echo", 5th byte space or NUL)
    la.abs  $t0, buf
    ld.w    $t1, $t0, 0
    li.w    $t2, 0x6f686365         # "echo" (little-endian)
    bne     $t1, $t2, 1f
    ld.bu   $t2, $t0, 4
    beq     $t2, $zero, do_echo
    li.w    $t3, 32                 # space
    beq     $t2, $t3, do_echo
1:
    la.abs  $a0, buf
    la.abs  $a1, cmd_uname
    bl strcmp
    beq     $a0, $zero, do_uname
    la.abs  $a0, buf
    la.abs  $a1, cmd_ls
    bl strcmp
    beq     $a0, $zero, do_ls
    la.abs  $a0, buf
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
    bl strcmp
    beq     $a0, $zero, do_clear
    la.abs  $a0, buf
    la.abs  $a1, cmd_reset
    bl strcmp
    beq     $a0, $zero, do_reset
    # unknown
    la.abs  $a1, msg_unknown
    li.w    $a2, 8
    bl write1
    la.abs  $a1, buf
    move    $a2, $s0
    bl write1
    la.abs  $a1, msg_unknown2
    li.w    $a2, 20
    bl write1
    b       mainloop

# ---------------- help ----------------
do_help:
    la.abs  $a1, msg_help
    li.w    $a2, 80
    bl write1
    b       mainloop

# ---------------- echo ----------------
do_echo:
    # print from buf+4; skip the space if present
    la.abs  $t0, buf
    addi.w  $t0, $t0, 4
    ld.bu   $t1, $t0, 0
    li.w    $t2, 32                 # space
    bne     $t1, $t2, 1f
    addi.w  $t0, $t0, 1             # skip space
    addi.w  $s0, $s0, -1
1:  # length = (adjusted s0) - 4
    addi.w  $a2, $s0, -4
    blt     $a2, $zero, do_echo_empty
    move    $a1, $t0
    bl write1
do_echo_empty:
    la.abs  $a1, newline
    li.w    $a2, 1
    bl write1
    b       mainloop

# ---------------- uname ----------------
do_uname:
    la.abs  $a0, unambuf
    li.w    $a7, 160
    syscall 0
    la.abs  $a1, unambuf
    li.w    $a2, 65
    bl write1
    la.abs  $a1, newline
    li.w    $a2, 1
    bl write1
    b       mainloop

# ---------------- clear ----------------
do_clear:
    la.abs  $a1, ansi_clear
    li.w    $a2, 11
    bl write1
    b       mainloop

# ---------------- reset (restart shell) ----------------
do_reset:
    b       _start

# ---------------- cd <dir> ----------------
do_cd:
    la.abs  $a0, buf
    addi.w  $a0, $a0, 3              # chdir(path): 路径在 a0(不是 openat 的 a1!)
    li.w    $a7, 49                  # chdir
    syscall 0
    blt     $a0, $zero, cd_fail
    b       mainloop
cd_fail:
    la.abs  $a1, msg_cdfail
    li.w    $a2, 22
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
do_cat:
    addi.w  $a2, $s0, -4
    blt     $a2, $zero, mainloop
    # openat(AT_FDCWD=-100, path, O_RDONLY=0)
    li.w    $a0, -100
    la.abs  $a1, buf
    addi.w  $a1, $a1, 4
    li.w    $a2, 0
    li.w    $a3, 0
    li.w    $a7, 56
    syscall 0
    blt     $a0, $zero, cat_fail
    move    $s2, $a0
cat_loop:
    move    $a0, $s2
    la.abs  $a1, buf
    li.w    $a2, 256
    li.w    $a7, 63
    syscall 0
    blt     $a0, $zero, cat_done
    beq     $a0, $zero, cat_done
    move    $a2, $a0
    la.abs  $a1, buf
    li.w    $a0, 1
    li.w    $a7, 64
    syscall 0
    b       cat_loop
cat_done:
    move    $a0, $s2
    li.w    $a7, 57
    syscall 0
    la.abs  $a1, newline
    li.w    $a2, 1
    bl write1
    b       mainloop
cat_fail:
    la.abs  $a1, msg_catfail
    li.w    $a2, 30
    bl write1
    b       mainloop

# ---------------- ls (按当前目录) ----------------
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

ls_close:
    move    $a0, $s2
    li.w    $a7, 57
    syscall 0
ls_done:
    la.abs  $a1, newline
    li.w    $a2, 1
    bl write1
    b       mainloop

# ---------------- strcmp (a0, a1 -> a0) ----------------
strcmp:
    ld.bu   $t0, $a0, 0
    ld.bu   $t1, $a1, 0
    bne     $t0, $t1, strdiff
    beq     $t0, $zero, streq
    addi.w  $a0, $a0, 1
    addi.w  $a1, $a1, 1
    b       strcmp
streq:
    li.w    $a0, 0
    jirl    $zero, $ra, 0
strdiff:
    sub.w   $a0, $t0, $t1
    jirl    $zero, $ra, 0

# ---------------- write1: write(1, a1, a2) ----------------
write1:
    li.w    $a0, 1
    li.w    $a7, 64
    syscall 0
    jirl    $zero, $ra, 0

# ---------------- data ----------------
    .data
banner: .ascii "\nT26 minimal shell (NOP-Core LA32R) - builtin: help echo uname ls cat cd pwd clear\n"
prompt: .ascii "nop$ "
newline:.ascii "\n"
space:  .ascii " "
dot:    .asciz "."
cmd_help:  .asciz "help"
cmd_echo:  .asciz "echo"
cmd_uname: .asciz "uname"
cmd_ls:    .asciz "ls"
cmd_cat:   .asciz "cat"
cmd_clear: .asciz "clear"
cmd_reset: .asciz "reset"
msg_unknown:  .ascii "nop-sh: "
msg_unknown2: .ascii ": command not found\n"
msg_catfail:  .ascii "nop-sh: cat: cannot open file\n"
msg_help: .ascii "builtin commands: help echo <text> uname ls cat <file> cd <dir> pwd clear reset\n"
ansi_clear: .ascii "\033[2J\033[H"
msg_lsroot: .ascii ". .. dev proc sys tmp init \n"
msg_lsdev:  .ascii ". .. console null ttyS0 \n"
msg_lsdot:  .ascii ". .. \n"
msg_cdfail: .ascii "nop-sh: cd: cannot cd\n"
path_root: .asciz "/"
path_dev:  .asciz "/dev"
path_proc: .asciz "/proc"
path_sys:  .asciz "/sys"
path_tmp:  .asciz "/tmp"
cmd_cd:    .asciz "cd"
cmd_pwd:   .asciz "pwd"
cwdbuf:   .space 256
buf:      .space 1024
unambuf:  .space 512
dentbuf:  .space 4096
