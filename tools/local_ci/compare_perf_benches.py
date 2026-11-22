#!/usr/bin/env python3
"""对比两次 xsim perf 运行的 PERF_BENCH 周期计数(基线 vs 预取)。"""
import re
import sys
import io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

def parse(path):
    benches = {}
    done = False
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.search(r"PERF_BENCH (\d+) CYCLES (\d+)", line)
            if m:
                benches[int(m.group(1))] = int(m.group(2))
            if "PERF_ALL_BENCHES_DONE" in line:
                done = True
    return benches, done

def main():
    base_path, new_path = sys.argv[1], sys.argv[2]
    base, base_done = parse(base_path)
    new, new_done = parse(new_path)
    print(f"baseline: {len(base)} benches, all_done={base_done}  ({base_path})")
    print(f"prefetch: {len(new)} benches,  all_done={new_done}  ({new_path})")
    print()
    print(f"{'bench':>5} {'base_cyc':>10} {'pf_cyc':>10} {'speedup':>8}")
    total_base = total_new = 0
    n = 0
    for idx in sorted(set(base) | set(new)):
        b = base.get(idx)
        p = new.get(idx)
        if b is not None and p is not None:
            sp = b / p
            total_base += b
            total_new += p
            n += 1
            print(f"{idx:>5} {b:>10} {p:>10} {sp:>7.3f}x")
        else:
            print(f"{idx:>5} {str(b):>10} {str(p):>10} {'-':>8}")
    if n:
        print("-" * 35)
        print(f"{'AGG':>5} {total_base:>10} {total_new:>10} {total_base/total_new:>7.3f}x")

if __name__ == "__main__":
    main()
