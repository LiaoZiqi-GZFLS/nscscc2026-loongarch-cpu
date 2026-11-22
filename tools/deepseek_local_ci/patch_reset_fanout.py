#!/usr/bin/env python3
"""freq200 reset-fanout patch (post-regen netlist pass).

问题:MyCPUCore 内约 7000 个 `always @(posedge aclk or negedge aresetn)`
寄存器共享同一根异步复位网,综合后合并成单一高扇出网(旧布线报告
fo=6956,布线 6.3ns,recovery WNS -2.708 / 2983 端点)。

修法:在 MyCPUCore 内把复位端口 aresetn 重命名为带 max_fanout 属性的
内部网 aresetn_i(`(* max_fanout = 200 *) wire aresetn_i; assign aresetn_i = aresetn;`),
综合器据此复制 LUT 驱动,把复位扇出拆成 ~35 组、每组短布线。
仅文本级改写,不改逻辑语义;端口映射与子模块不受影响。

用法: python3 patch_reset_fanout.py <mycpu_top.v> [输出路径]
"""

import re
import sys


def patch(text: str) -> str:
    lines = text.split("\n")
    # 定位 MyCPUCore 模块区间
    start = end = None
    for i, ln in enumerate(lines):
        if re.match(r"\s*module MyCPUCore\s*\(", ln):
            start = i
        if start is not None and re.match(r"\s*endmodule\s*$", ln):
            end = i
            break
    if start is None or end is None:
        raise SystemExit("ERROR: MyCPUCore module not found")

    mod_lines = lines[start : end + 1]
    n_reset_refs = sum(1 for ln in mod_lines if "negedge aresetn" in ln or "aresetn" in ln)
    print(f"MyCPUCore: lines {start+1}-{end+1}, reset refs ~{n_reset_refs}")

    # 1) 在模块头部(端口表之后、首个 wire/reg 声明之前)插入别名网
    #    找端口列表结束行:包含 ");" 且其后没有 output/input 的行
    insert_at = None
    in_ports = True
    for i, ln in enumerate(mod_lines):
        if in_ports and re.search(r"\)\s*;\s*$", ln):
            insert_at = i + 1
            in_ports = False
            break
    if insert_at is None:
        raise SystemExit("ERROR: MyCPUCore port list end not found")
    alias = [
        "  (* max_fanout = 200 *) wire aresetn_i;",
        "  assign aresetn_i = aresetn;",
        "",
    ]
    mod_lines[insert_at:insert_at] = alias

    # 2) 模块体内所有 aresetn 引用改为 aresetn_i(端口声明行/别名行除外);
    #    端口映射行 .aresetn (x) 中端口名前有 '.', 用负向 lookbehind 保留端口名,
    #    只改连接表达式
    def is_port_decl(ln: str) -> bool:
        return bool(re.match(r"\s*input\s+aresetn\b", ln)) or "aresetn_i" in ln

    for i, ln in enumerate(mod_lines):
        if is_port_decl(ln):
            continue
        if "aresetn" in ln:
            mod_lines[i] = re.sub(r"(?<!\.)aresetn", "aresetn_i", ln)

    lines[start : end + 1] = mod_lines
    return "\n".join(lines)


def main() -> None:
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else src
    with open(src, "r", encoding="utf-8") as f:
        text = f.read()
    out = patch(text)
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    print(f"patched: {src} -> {dst}")


if __name__ == "__main__":
    main()
