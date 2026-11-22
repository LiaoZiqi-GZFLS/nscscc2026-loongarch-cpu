#!/usr/bin/env python3
"""LoongArch32R 功能仿真器 + 分支轨迹捕获。
用途:离线跑 nscscc_perf allbench,逐项记录周期数与分支轨迹,
供 gselect PHT 配置对比(32K/8K × h7/h5 × 零/弱跳转初值)。
"""
import struct, sys

class LoongArchEmu:
    PAGE = 4096
    def __init__(self):
        self.pages = {}            # page_idx -> bytearray(4096) 稀疏内存
        self.regs = [0]*32
        self.pc = 0
        self.cycles = 0            # 仿真周期模型 = 指令数(+ 由 BPU 模型后加误预测惩罚)
        self.switch = 0
        self.num_monitor = 0
        self.cr0 = 0               # IO_SIMU/CR0(软件写)
        self.uart_out = []
        self.trace = []            # (pc, taken) 已退休分支轨迹
        self.mem_trace = []        # (addr, is_write, size) 访存轨迹
        self.fetch_trace = []      # 取指地址(32 位对齐)
        self.num_writes = []       # (cycle, value) num_data 写入
        self.halted = False
        self.halt_reason = ""
        self.pc_hist = []
        self.perfcnt_base = 0      # perfcnt CSR 起始值
        self.csrs = {}

    def load_bin(self, path, base=0x1c000000):
        with open(path, "rb") as f:
            data = f.read()
        for i, b in enumerate(data):
            a = base + i
            pg = a >> 12
            if pg not in self.pages:
                self.pages[pg] = bytearray(self.PAGE)
            self.pages[pg][a & 0xFFF] = b
        self.pc = base

    def _norm(self, a):
        a &= 0xFFFFFFFF
        if 0x80000000 <= a <= 0x9FFFFFFF:   # 缓存窗口 -> 物理
            a &= 0x1FFFFFFF
        return a

    def _get_page(self, a):
        a = self._norm(a)
        return self.pages.get(a >> 12)

    # ---- 内存 ----
    def read32(self, a):
        a &= 0xFFFFFFFF
        if 0xBFE001C0 <= a <= 0xBFE00200:
            return 0xFFFFFFFF   # UART 寄存器读:全就绪(TX 空/RX 满)
        if 0xBFAFF000 <= a <= 0xBFAFFFFF:
            return self._mmio_read(a)
        pg = self._get_page(a)
        if pg is None:
            return 0
        self.mem_trace.append((a & 0x1FFFFFFF, False, 4))
        return struct.unpack_from("<I", pg, (a & 0x1FFFFFFF) & 0xFFF)[0]

    def write32(self, a, v):
        a &= 0xFFFFFFFF
        v &= 0xFFFFFFFF
        if 0xBFE001C0 <= a <= 0xBFE00200:
            if a == 0xBFE001E0:
                self.uart_out.append(v & 0xFF)
            return
        if 0xBFAFF000 <= a <= 0xBFAFFFFF:
            self._mmio_write(a, v)
            return
        n = self._norm(a)
        pg = n >> 12
        if pg not in self.pages:
            self.pages[pg] = bytearray(self.PAGE)
        self.mem_trace.append((n, True, 4))
        struct.pack_into("<I", self.pages[pg], n & 0xFFF, v)

    def read8(self, a):
        if 0xBFE001C0 <= a <= 0xBFE00200:
            return 0xFF   # UART 状态全就绪
        if 0xBFAFF000 <= a <= 0xBFAFFFFF:
            return self._mmio_read(a) & 0xFF
        pg = self._get_page(a)
        if pg is None:
            return 0
        self.mem_trace.append((a & 0x1FFFFFFF, False, 1))
        return pg[(a & 0x1FFFFFFF) & 0xFFF]

    def write8(self, a, v):
        if 0xBFE001C0 <= a <= 0xBFE00200:
            if a == 0xBFE001E0:
                self.uart_out.append(v & 0xFF)
            return
        if 0xBFAFF000 <= a <= 0xBFAFFFFF:
            self._mmio_write(a, v & 0xFF)
            return
        n = self._norm(a)
        pg = n >> 12
        if pg not in self.pages:
            self.pages[pg] = bytearray(self.PAGE)
        self.mem_trace.append((n, True, 1))
        self.pages[pg][n & 0xFFF] = v & 0xFF

    def _mmio_read(self, a):
        off = a - 0xBFAFF000
        if off == 0x10: return 0xBFE001E0   # UART_ADDR → UART 基址
        if off == 0x60: return self.switch  # SWITCH
        if off == 0x00: return self.cr0     # IO_SIMU/CR0
        if off == 0x40: return self.num_monitor
        if off == 0x50: return self.last_num
        return 0

    def _mmio_write(self, a, v):
        off = a - 0xBFAFF000
        if off == 0x00: self.cr0 = v
        elif off == 0x40: self.num_monitor = v & 1
        elif off == 0x50:
            self.last_num = v
            self.num_writes.append((self.cycles, v))

    def halt(self, reason):
        self.halted = True
        self.halt_reason = reason
        print("HALT: %s" % reason)
        print("pc=%08x" % self.pc)
        for hpc, hins in self.pc_hist[-15:]:
            print("    %08x: %08x" % (hpc, hins))
        for i, r in enumerate(self.regs):
            if r:
                print("  r%02d=%08x" % (i, r), end="")
        print()

    # ---- CSR ----
    def csr_read(self, n):
        if 0x20 <= n <= 0x23:      # perfcnt
            return (self.perfcnt_base + self.cycles) & 0xFFFFFFFF
        return self.csrs.get(n, 0)

    def csr_write(self, n, v):
        if 0x20 <= n <= 0x23:
            self.perfcnt_base = v - self.cycles
            return
        self.csrs[n] = v

    # ---- 执行 ----
    def step(self):
        if self.halted:
            return
        self.fetch_trace.append(self.pc & 0x1FFFFFFF)
        self.pc_hist.append((self.pc, self.read32(self.pc)))
        ins = self.read32(self.pc)
        if ins == 0x03400000:   # andi r0,r0,0
            self.pc += 4; self.cycles += 1
            return
        self._exec(ins)
        self.cycles += 1

    def _rd(self, n):
        return 0 if n == 0 else self.regs[n]

    def _wr(self, n, v):
        if n != 0:
            self.regs[n] = v & 0xFFFFFFFF

    def _exec(self, ins):
        op = ins >> 26
        if op == 0x00:   # ALU 组(立即数/寄存器/移位/cpucfg)
            self._exec_0x00(ins); return
        if op == 0x01:   # CSR / cacop
            self._exec_0x01(ins); return
        if op == 0x05:   # lu12i.w
            rd = ins & 0x1F
            self._wr(rd, self._sx((ins >> 5) & 0xFFFFF, 20) << 12)
            self.pc += 4; return
        if op == 0x06:   # pcaddi
            rd = ins & 0x1F
            self._wr(rd, self.pc + self._sx((ins >> 5) & 0x1FFFFF, 21) * 4)
            self.pc += 4; return
        if op == 0x07:   # pcaddu12i
            rd = ins & 0x1F
            self._wr(rd, self.pc + self._sx((ins >> 5) & 0xFFFFF, 20) * 4096)
            self.pc += 4; return
        if op == 0x08:   # ll/sc
            self.halt("unimpl ll/sc pc=%08x ins=%08x" % (self.pc, ins)); return
        if op == 0x0A:   # ld/st
            self._exec_0x0A(ins); return
        if op == 0x10:   # beqz
            rj = (ins >> 5) & 0x1F
            offs = self._sx((ins >> 10) & 0xFFFF, 16) * 4
            self._branch(self._rd(rj) == 0, offs); return
        if op == 0x11:   # bnez
            rj = (ins >> 5) & 0x1F
            offs = self._sx((ins >> 10) & 0xFFFF, 16) * 4
            self._branch(self._rd(rj) != 0, offs); return
        if op == 0x12:   # bceqz / bcnez
            rj = (ins >> 5) & 0x1F
            cj = (ins >> 8) & 1
            offs = self._sx((ins >> 10) & 0xFFFF, 16) * 4
            taken = (self._rd(rj) == 0) == (cj == 0)
            self._branch(taken, offs); return
        if op == 0x13:   # jirl
            rj = (ins >> 5) & 0x1F; rd = ins & 0x1F
            offs = self._sx((ins >> 10) & 0xFFFF, 16) * 4
            npc = self.pc + 4
            self.trace.append((self.pc, 1))
            if rd != 0: self._wr(rd, npc)
            self.pc = (self._rd(rj) + offs) & 0xFFFFFFFC; return
        if op in (0x14, 0x15):   # b/bl: offs = sign26({inst[9:0], inst[25:10]}) * 4,32 位回绕
            f26 = ((ins & 0x3FF) << 16) | ((ins >> 10) & 0xFFFF)
            offs = self._sx(f26, 26) * 4
            self.trace.append((self.pc, 1))
            if op == 0x15:
                self._wr(1, self.pc + 4)   # BL 恒写 ra(rd 字段被 overrideRdToRA 覆盖)
            self.pc = (self.pc + offs) & 0xFFFFFFFF; return
        if op in (0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B):   # beq/bne/blt/bge/bltu/bgeu
            rj = (ins >> 5) & 0x1F; rd = ins & 0x1F
            offs = self._sx((ins >> 10) & 0xFFFF, 16) * 4
            a, b = self._rd(rj), self._rd(rd)
            if op == 0x16: self._branch(a == b, offs)
            elif op == 0x17: self._branch(a != b, offs)
            elif op == 0x18: self._branch(self._s32(a) < self._s32(b), offs)
            elif op == 0x19: self._branch(self._s32(a) >= self._s32(b), offs)
            elif op == 0x1A: self._branch(a < b, offs)
            else: self._branch(a >= b, offs)
            return
        if op == 0x1E:   # break/syscall 等
            if ((ins >> 22) & 0xF) == 0x8:
                self.halt("break pc=%08x code=%d" % (self.pc, ins & 0x7FFF))
            else:
                self.halt("unimpl 0x1E pc=%08x ins=%08x" % (self.pc, ins))
            return
        self.halt("unimpl op %02X pc=%08x ins=%08x" % (op, self.pc, ins))

    def _branch(self, taken, offs):
        self.trace.append((self.pc, 1 if taken else 0))
        self.pc += offs if taken else 4

    def _exec_0x00(self, ins):
        b2522 = (ins >> 22) & 0xF
        rd = ins & 0x1F; rj = (ins >> 5) & 0x1F
        if b2522 in (8, 9, 10, 13, 14, 15):   # 立即数 ALU
            imm = self._sx((ins >> 10) & 0xFFF, 12)
            a = self._rd(rj)
            if b2522 == 8: self._wr(rd, 1 if self._s32(a) < imm else 0)      # slti
            elif b2522 == 9: self._wr(rd, 1 if a < (imm & 0xFFFFFFFF) else 0) # sltui
            elif b2522 == 10: self._wr(rd, a + imm)                          # addi.w
            elif b2522 == 13: self._wr(rd, a & imm)                          # andi
            elif b2522 == 14: self._wr(rd, a | imm)                          # ori
            else: self._wr(rd, a ^ imm)                                      # xori
            self.pc += 4; return
        if b2522 == 0:
            b2115 = (ins >> 15) & 0x7F
            b1410 = (ins >> 10) & 0x1F
            if b2115 == 0 and b1410 in (24, 25, 26):   # rdtimel.w/rdtimeh.w/rdtime.d
                self._wr(rd, self.cycles & 0xFFFFFFFF)
                self.pc += 4; return
            if b2115 == 0 and b1410 == 27:    # cpucfg → 恒 0
                self._wr(rd, 0)
                self.pc += 4; return
            rk = (ins >> 10) & 0x1F
            a = self._rd(rj); b = self._rd(rk)
            if b2115 == 32: self._wr(rd, a + b)                       # add.w
            elif b2115 == 34: self._wr(rd, a - b)                     # sub.w
            elif b2115 == 36: self._wr(rd, 1 if self._s32(a) < self._s32(b) else 0)  # slt
            elif b2115 == 37: self._wr(rd, 1 if a < b else 0)         # sltu
            elif b2115 == 40: self._wr(rd, ~(a | b))                  # nor
            elif b2115 == 41: self._wr(rd, a & b)                     # and
            elif b2115 == 42: self._wr(rd, a | b)                     # or / move
            elif b2115 == 43: self._wr(rd, a ^ b)                     # xor
            elif b2115 == 44: self._wr(rd, a | ~b)                    # orn
            elif b2115 == 45: self._wr(rd, a & ~b)                    # andn
            elif b2115 == 46: self._wr(rd, (a << (b & 0x1F)) & 0xFFFFFFFF)  # sll.w
            elif b2115 == 47: self._wr(rd, a >> (b & 0x1F))           # srl.w
            elif b2115 == 48: self._wr(rd, self._s32(a) >> (b & 0x1F))  # sra.w
            elif b2115 == 49: self._wr(rd, ((a >> (b & 0x1F)) | (a << (32 - (b & 0x1F)))) & 0xFFFFFFFF)  # rotr.w
            elif b2115 == 56: self._wr(rd, (a * b) & 0xFFFFFFFF)      # mul.w
            elif b2115 == 57: self._wr(rd, (self._s32(a) * self._s32(b)) >> 32)  # mulh.w
            elif b2115 == 58: self._wr(rd, (a * b) >> 32)             # mulh.wu
            elif b2115 == 64:
                if b == 0: self.halt("div0 pc=%08x" % self.pc); return
                q = abs(self._s32(a)) // abs(self._s32(b))
                if (self._s32(a) < 0) != (self._s32(b) < 0): q = -q
                self._wr(rd, q)                                        # div.w(向零截断)
            elif b2115 == 65:
                if b == 0: self.halt("mod0 pc=%08x" % self.pc); return
                q = abs(self._s32(a)) // abs(self._s32(b))
                if (self._s32(a) < 0) != (self._s32(b) < 0): q = -q
                self._wr(rd, self._s32(self._s32(a) - q * self._s32(b)))  # mod.w
            elif b2115 == 66:
                if b == 0: self.halt("divu0 pc=%08x" % self.pc); return
                self._wr(rd, a // b)                                  # div.wu
            elif b2115 == 67:
                if b == 0: self.halt("modu0 pc=%08x" % self.pc); return
                self._wr(rd, a % b)                                   # mod.wu
            elif b2115 == 84:
                self.halt("break pc=%08x code=%d" % (self.pc, rk))    # break
                return
            else:
                self.halt("unimpl 0x00 reg b2115=%d pc=%08x ins=%08x" % (b2115, self.pc, ins))
                return
            self.pc += 4; return
        if b2522 == 1:   # 移位立即数:slli/srli/srai/rotri
            b2115 = (ins >> 15) & 0x7F
            uimm = (ins >> 10) & 0x1F
            a = self._rd(rj)
            if b2115 == 1: self._wr(rd, (a << uimm) & 0xFFFFFFFF)      # slli.w
            elif b2115 == 9: self._wr(rd, a >> uimm)                   # srli.w
            elif b2115 == 17: self._wr(rd, self._s32(a) >> uimm)       # srai.w
            elif b2115 == 25: self._wr(rd, ((a >> uimm) | (a << (32 - uimm))) & 0xFFFFFFFF)  # rotri.w
            else: self.halt("unimpl 0x00 shift b2115=%d pc=%08x" % (b2115, self.pc)); return
            self.pc += 4; return
        if b2522 in (2, 3):   # bstrins / bstrpick
            msbd = (ins >> 16) & 0x1F
            lsb = (ins >> 10) & 0x1F
            if b2522 == 3:    # bstrpick.w
                self._wr(rd, (self._rd(rj) >> lsb) & ((1 << (msbd - lsb + 1)) - 1))
            else:             # bstrins.w
                mask = ((1 << (msbd - lsb + 1)) - 1) << lsb
                self._wr(rd, (self._rd(rd) & ~mask) | ((self._rd(rj) << lsb) & mask))
            self.pc += 4; return
        self.halt("unimpl 0x00 b2522=%d pc=%08x ins=%08x" % (b2522, self.pc, ins))

    def _exec_0x01(self, ins):
        b2522 = (ins >> 22) & 0xF
        if b2522 == 8:   # cacop → nop
            self.pc += 4; return
        rd = ins & 0x1F; rj = (ins >> 5) & 0x1F
        csr = (ins >> 10) & 0x3FFF
        b2115 = (ins >> 15) & 0x7F
        if b2115 == 0:    # csrxchg
            old = self.csr_read(csr)
            mask = self._rd(rj)
            self.csr_write(csr, (old & ~mask) | (self._rd(rd) & mask))
            self._wr(rd, old)
        elif b2115 == 8:  # csrrd
            self._wr(rd, self.csr_read(csr))
        elif b2115 == 12: # csrwr
            old = self.csr_read(csr)
            self.csr_write(csr, self._rd(rd))
            self._wr(rd, old)
        else:
            self.halt("unimpl 0x01 b2115=%d pc=%08x" % (b2115, self.pc)); return
        self.pc += 4

    def _exec_0x0A(self, ins):
        rd = ins & 0x1F; rj = (ins >> 5) & 0x1F
        imm = self._sx((ins >> 10) & 0xFFF, 12)
        sel = (ins >> 22) & 0xF
        a = self._rd(rj) + imm
        if sel == 0: self._wr(rd, self._sx(self.read8(a), 8))                    # ld.b
        elif sel == 1: self._wr(rd, self._sx(self.read8(a) | (self.read8(a+1) << 8), 16))  # ld.h
        elif sel == 2: self._wr(rd, self.read32(a))                              # ld.w
        elif sel == 4: self.write8(a, self._rd(rd))                              # st.b
        elif sel == 5:
            v = self._rd(rd); self.write8(a, v); self.write8(a+1, v >> 8)        # st.h
        elif sel == 6: self.write32(a, self._rd(rd))                             # st.w
        elif sel == 8: self._wr(rd, self.read8(a))                               # ld.bu
        elif sel == 9: self._wr(rd, self.read8(a) | (self.read8(a+1) << 8))      # ld.hu
        else: self.halt("unimpl 0x0A sel=%d pc=%08x ins=%08x" % (sel, self.pc, ins)); return
        self.pc += 4


    def _sx(self, v, bits):
        v &= (1 << bits) - 1
        return v - (1 << bits) if v & (1 << (bits - 1)) else v
    def _s32(self, v):
        return v - 0x100000000 if v & 0x80000000 else v

    def run(self, max_cycles=10_000_000, num_watch=False):
        while not self.halted and self.cycles < max_cycles:
            self.step()
            if num_watch and self.num_writes:
                break
        return self.num_writes

def run_bench(bin_path, bench_idx, switch_enc, max_cycles=50_000_000):
    e = LoongArchEmu()
    e.load_bin(bin_path)
    e.switch = 0x80 | (0x7F - switch_enc)
    e.last_num = 0
    e.run(max_cycles=max_cycles)
    if e.num_writes:
        cyc, val = e.num_writes[0]
        print("BENCH %d: cycles=%d num=%08x halted=%s" % (bench_idx, cyc, val, e.halt_reason))
    else:
        print("BENCH %d: NO NUM WRITE, halted=%s cycles=%d" % (bench_idx, e.halt_reason, e.cycles))
    return e

if __name__ == "__main__":
    bin_path = r"D:\code\Vivado\Loongarch_workspace\chiplab\software\examples\nscscc_perf\obj\allbench\inst_data.bin"
    idx = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    e = run_bench(bin_path, idx, idx, max_cycles=80_000_000)
    print("uart:", bytes(e.uart_out[-100:]))
    print("trace branches:", len(e.trace))
