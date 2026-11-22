#!/usr/bin/env python3
"""gselect PHT 配置对比:在模拟器产生的已退休分支流上,
对比 h7/32K vs h7/8K vs h5/8K × 零/弱跳转初值 的误预测数与建模周期。
"""
import sys
sys.path.insert(0, r"D:\code\Vivado\Loongarch_workspace\local_ci")
from loongarch_emu import LoongArchEmu

BTB_SETS = 1024
FETCH_PENALTY = 15  # 每次误预测的建模惩罚周期(相对比较,数值不敏感)

class BPUModel:
    def __init__(self, pht_sets, hist, init_counter):
        self.pht = [init_counter] * pht_sets
        self.hist = hist
        self.mask = (1 << hist) - 1
        self.w = pht_sets.bit_length() - 1 - hist   # PC 参与索引的位数
        self.ghr = 0
        self.btb_valid = [0] * BTB_SETS
        self.btb_tag = [0] * BTB_SETS
        self.mispredicts = 0
        self.pred_taken_count = 0

    def branch(self, pc, taken):
        pcw = pc >> 2
        idx = ((self.ghr << self.w) | (pcw & ((1 << self.w) - 1))) & (len(self.pht) - 1)
        cnt = self.pht[idx]
        btb_idx = pcw & (BTB_SETS - 1)
        tag = pcw >> 10
        btb_hit = self.btb_valid[btb_idx] and self.btb_tag[btb_idx] == tag
        pred_taken = btb_hit and cnt >= 2
        if pred_taken != taken:
            self.mispredicts += 1
        if pred_taken:
            self.pred_taken_count += 1
        # 计数器更新(饱和 ±1 向真实方向)
        if taken and cnt < 3:
            self.pht[idx] = cnt + 1
        elif not taken and cnt > 0:
            self.pht[idx] = cnt - 1
        # GHR 更新
        self.ghr = ((self.ghr << 1) | (1 if taken else 0)) & self.mask
        # BTB 更新(简化:taken 分支分配,aliasing 同真实直接映射)
        if taken and not btb_hit:
            self.btb_valid[btb_idx] = 1
            self.btb_tag[btb_idx] = tag

    def modeled_cycles(self, instrs):
        return instrs + self.mispredicts * FETCH_PENALTY

def run_configs(bin_path, bench_idx, configs):
    """跑一遍仿真器,把已退休分支流同时喂给所有配置模型。"""
    e = LoongArchEmu()
    e.load_bin(bin_path)
    e.switch = 0x80 | (0x7F - bench_idx)
    e.last_num = 0
    models = [BPUModel(cfg[1], cfg[2], cfg[3]) for cfg in configs]
    pos = 0
    while not e.halted and e.cycles < 400_000_000:
        e.step()
        if e.num_writes:
            break
        # 消费新增分支(增量切片,定期截断避免内存增长)
        if len(e.trace) > pos:
            new = e.trace[pos:]
            pos = len(e.trace)
            for pc, taken in new:
                for m in models:
                    m.branch(pc, taken)
            if pos > 200000:
                del e.trace[:pos]
                pos = 0
    if e.num_writes:
        cyc, val = e.num_writes[0]
        return e.cycles, e.num_writes[0], models, e.halt_reason
    return e.cycles, None, models, e.halt_reason

def main():
    bin_path = r"D:\code\Vivado\Loongarch_workspace\chiplab\software\examples\nscscc_perf\obj\allbench\inst_data.bin"
    configs = [
        ("h7/32K z0", 32768, 7, 0),
        ("h7/32K w1", 32768, 7, 1),
        ("h7/8K  z0", 8192, 7, 0),
        ("h7/8K  w1", 8192, 7, 1),
        ("h5/8K  z0", 8192, 5, 0),
        ("h5/8K  w1", 8192, 5, 1),
    ]
    benches = [(i, i) for i in range(1, 21)]
    only = [int(x) for x in sys.argv[1:]] or None
    print("%-6s %-12s %12s %12s" % ("bench", "config", "mispredict", "cycles(=instr+15*mpr)"))
    for bench_idx, enc in benches:
        if only and bench_idx not in only:
            continue
        total_instr, numwr, models, reason = run_configs(bin_path, enc, configs)
        if numwr is None:
            print("bench %2d: NO RESULT (halt=%s instr=%d)" % (bench_idx, reason, total_instr), flush=True)
            continue
        for (name, _, _, _), m in zip(configs, models):
            print("%-6d %-12s %12d %12d" % (bench_idx, name, m.mispredicts, m.modeled_cycles(total_instr)))
        print()

if __name__ == "__main__":
    main()
