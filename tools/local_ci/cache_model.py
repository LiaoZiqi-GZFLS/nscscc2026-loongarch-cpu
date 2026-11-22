#!/usr/bin/env python3
"""D$ 多路组相联策略与 L2 的离线评估:踪迹驱动的缓存模拟。
基于 loongarch_emu 的访存/取指轨迹,在 DDR 显著延迟下对比配置。"""
import sys, math, pickle, os
sys.path.insert(0, r"D:\code\Vivado\Loongarch_workspace\local_ci")
from loongarch_emu import LoongArchEmu

LINE = 64
DDR_PENALTY = 100      # DDR 原始延迟(对齐平台 R 延迟 ~85-170 周期)
DDR_EFFECTIVE = 40     # OoO 延迟隐藏后的有效惩罚(悲观/乐观两档)
L2_HIT_PENALTY = 8
ICACHE = (16, 2)       # I$ 固定 16KB 2-way

class Cache:
    def __init__(self, size_kb, ways, repl="lru"):
        self.line = LINE
        self.ways = ways
        self.sets = max(1, size_kb * 1024 // (LINE * ways))
        self.repl = repl
        # 每路: [tag, valid, dirty, lru]
        self.ways_state = [[[0, 0, 0, 0] for _ in range(ways)] for _ in range(self.sets)]
        self.tick = 0
        self.hits = 0
        self.misses = 0
        self.writebacks = 0

    def access(self, addr, is_write):
        a = addr & 0xFFFFFFFF
        tag = a // LINE
        idx = tag % self.sets
        st = self.ways_state[idx]
        self.tick += 1
        for w in st:
            if w[1] and w[0] == tag:
                w[3] = self.tick
                self.hits += 1
                if is_write:
                    w[2] = 1
                return True
        # miss
        self.misses += 1
        # 选牺牲行
        if self.repl == "lru":
            victim = min(range(self.ways), key=lambda i: st[i][3])
        else:  # round-robin
            victim = self.tick % self.ways
        if st[victim][1] and st[victim][2]:
            self.writebacks += 1
        st[victim] = [tag, 1, 1 if is_write else 0, self.tick]
        return False

class L2Cache(Cache):
    pass

class PrefetchCache(Cache):
    """带下一行预取的缓存:访问行 L 时后台预取 L+1,完成时间 = 当前周期 + 延迟。
    需求访问时:已预取完成 -> 命中;预取在途 -> 加剩余延迟;未预取 -> 全延迟。"""
    def __init__(self, size_kb, ways, repl="lru", latency=DDR_EFFECTIVE):
        super().__init__(size_kb, ways, repl)
        self.latency = latency
        self.pf_done = {}    # line_tag -> 完成周期
        self.pf_hits = 0
        self.pf_partial = 0

    def demand(self, addr, is_write, cycle):
        a = addr & 0xFFFFFFFF
        tag = a // LINE
        if self._hit(tag, is_write):
            self._issue_pf(tag + 1, cycle)
            return 0
        # 预取完成的 -> 视为命中(已入缓存)
        if tag in self.pf_done and self.pf_done[tag] <= cycle:
            self._fill(tag, is_write)
            self.pf_hits += 1
            self._issue_pf(tag + 1, cycle)
            return 0
        # 预取在途 -> 剩余延迟
        if tag in self.pf_done:
            rem = self.pf_done[tag] - cycle
            self._fill(tag, is_write)
            self.pf_partial += rem
            self._issue_pf(tag + 1, cycle)
            return rem
        # 纯缺失
        self.misses += 1
        self._fill(tag, is_write)
        self._issue_pf(tag + 1, cycle)
        return self.latency

    def _hit(self, tag, is_write):
        idx = tag % self.sets
        st = self.ways_state[idx]
        self.tick += 1
        for w in st:
            if w[1] and w[0] == tag:
                w[3] = self.tick
                self.hits += 1
                if is_write:
                    w[2] = 1
                return True
        return False

    def _fill(self, tag, is_write):
        idx = tag % self.sets
        st = self.ways_state[idx]
        self.tick += 1
        victim = min(range(self.ways), key=lambda i: st[i][3]) if self.repl == "lru" else self.tick % self.ways
        if st[victim][1] and st[victim][2]:
            self.writebacks += 1
        st[victim] = [tag, 1, 1 if is_write else 0, self.tick]

    def _issue_pf(self, tag, cycle):
        if tag not in self.pf_done:
            self.pf_done[tag] = cycle + self.latency

def simulate_prefetch(conf, d_trace, i_trace, instr):
    d_size, d_ways, repl, _ = conf
    d = PrefetchCache(d_size, d_ways, repl)
    i = PrefetchCache(ICACHE[0], ICACHE[1], "lru")
    cyc = 0
    for addr, isw, sz in d_trace:
        cyc += d.demand(addr, isw, cyc)
    for addr in i_trace:
        cyc += i.demand(addr, False, cyc)
    return cyc + instr, d.misses, i.misses, d.pf_hits, d.pf_partial, d.writebacks + i.writebacks

def simulate(conf, d_trace, i_trace, instr):
    d_size, d_ways, repl, l2_size = conf
    d = Cache(d_size, d_ways, repl)
    i = Cache(ICACHE[0], ICACHE[1], "lru")
    l2 = Cache(l2_size, 8, "lru") if l2_size else None
    for addr, isw, sz in d_trace:
        if not d.access(addr, isw):
            if l2 and l2.access(addr, isw):
                pass
    for addr in i_trace:
        if not i.access(addr, False):
            if l2 and l2.access(addr, False):
                pass
    l2_hits = l2.hits if l2 else 0
    l2_misses = l2.misses if l2 else (d.misses + i.misses)
    l2_wb = l2.writebacks if l2 else 0
    cyc_raw = instr + (d.misses + i.misses) * DDR_PENALTY + (d.writebacks + i.writebacks) * DDR_PENALTY
    cyc_eff = instr + (d.misses + i.misses) * DDR_EFFECTIVE + (d.writebacks + i.writebacks) * DDR_EFFECTIVE
    if l2:
        cyc_raw = instr + (d.misses + i.misses) * L2_HIT_PENALTY + (l2_misses + l2_wb) * DDR_PENALTY
        cyc_eff = instr + (d.misses + i.misses) * L2_HIT_PENALTY + (l2_misses + l2_wb) * DDR_EFFECTIVE
    return (d.misses, i.misses, l2_misses, d.writebacks, cyc_raw, cyc_eff)

BENCHES = [1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 13, 14]
BIN = r"D:\code\Vivado\Loongarch_workspace\chiplab\software\examples\nscscc_perf\obj\allbench\inst_data.bin"
TRACE_DIR = r"D:\code\Vivado\Loongarch_workspace\local_ci\cache_traces"

def get_trace(bench):
    fp = os.path.join(TRACE_DIR, "bench_%d.pkl" % bench)
    if os.path.exists(fp):
        with open(fp, "rb") as f:
            return pickle.load(f)
    e = LoongArchEmu()
    e.load_bin(BIN)
    e.switch = 0x80 | (0x7F - bench)
    e.last_num = 0
    while not e.halted and e.cycles < 400_000_000:
        e.step()
        if e.num_writes:
            break
    data = (e.mem_trace, e.fetch_trace, e.cycles, bool(e.num_writes))
    os.makedirs(TRACE_DIR, exist_ok=True)
    with open(fp, "wb") as f:
        pickle.dump(data, f)
    return data

CONFIGS = [
    ("D$8Kx2  (基线)",    (8, 2, "lru", 0)),
    ("D$16Kx4 (B)",      (16, 4, "rr", 0)),
    ("D$16Kx2",          (16, 2, "lru", 0)),
    ("D$8Kx4",           (8, 4, "lru", 0)),
    ("D$32Kx4",          (32, 4, "lru", 0)),
    ("D$16Kx8",          (16, 8, "lru", 0)),
    ("D$64Kx4",          (64, 4, "lru", 0)),
    ("D$8Kx2 + L2 128K", (8, 2, "lru", 128)),
    ("D$16Kx4 + L2 128K",(16, 4, "lru", 128)),
    ("D$16Kx4 + L2 256K",(16, 4, "lru", 256)),
]

def main():
    only = [int(x) for x in sys.argv[1:]] or BENCHES
    results = {name: [] for name, _ in CONFIGS}
    detail = {b: {} for b in only}
    for b in only:
        d_t, i_t, instr, ok = get_trace(b)
        if not ok:
            print("bench %d: NO RESULT (skip)" % b)
            continue
        for name, conf in CONFIGS:
            dm, im, l2m, wb, cyc_raw, cyc_eff = simulate(conf, d_t, i_t, instr)
            results[name].append(cyc_eff)
            detail[b][name] = (dm, cyc_eff)
        print("bench %d done (instr=%d)" % (b, instr), flush=True)
    print()
    print("%-20s %12s %12s" % ("config", "geomean cyc", "vs 基线"))
    # 预取对比(有效延迟模型)
    print()
    print("%-20s %12s %12s" % ("config(+prefetch)", "geomean cyc", "vs 同配无预取"))
    for name, conf in CONFIGS:
        r = []
        for b in only:
            if b in detail and detail[b]:
                cyc, dm, im, pfh, pfp, wb = simulate_prefetch(conf, *get_trace(b)[:2], get_trace(b)[2])
                r.append(cyc)
        g = math.exp(sum(math.log(v) for v in r) / len(r))
        baseg = math.exp(sum(math.log(detail[b][name][1]) for b in only if b in detail and detail[b]) / len(r))
        print("%-20s %12.0f %+8.2f%%" % (name, g, (g / baseg - 1) * 100))
    base = None
    for name, _ in CONFIGS:
        g = math.exp(sum(math.log(v) for v in results[name]) / len(results[name]))
        if base is None:
            base = g
        print("%-20s %12.0f %+8.2f%%" % (name, g, (g / base - 1) * 100))
    print()
    # 每基准明细(仅关键对比)
    print("%-6s %12s %12s %12s %12s" % ("bench", "8Kx2", "16Kx4(B)", "32Kx4", "+L2 128K"))
    for b in only:
        if b in detail and detail[b]:
            print("%-6d %s" % (b, " ".join("%12.0f" % detail[b].get(n, (0, 0))[1]
                  for n, _ in CONFIGS if n in ("D$8Kx2  (基线)", "D$16Kx4 (B)", "D$32Kx4", "D$8Kx2 + L2 128K"))))

if __name__ == "__main__":
    main()
