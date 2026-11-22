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
