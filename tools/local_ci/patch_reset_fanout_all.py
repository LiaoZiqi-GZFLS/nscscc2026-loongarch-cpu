#!/usr/bin/env python3
"""freq200 round-13 generalized reset-fanout patch.

round-13 网表的触发器分布在 24 个子模块(SpinalHDL 按 Area 分组生成
always 块), 原 patch_reset_fanout.py 只处理 MyCPUCore 已不适用。
本脚本对文件内**每个**带 aresetn 端口的模块做同样的事:
在模块内加 `(* max_fanout = 200 *) wire aresetn_i; assign aresetn_i = aresetn;`
并把模块内所有异步复位引用改到 aresetn_i, 让综合器按 ≤200 复制复位
驱动, 消除 mem_rstb 单网 4063 扇出的 recovery 违例。
仅文本级改写, 不改逻辑语义。

用法: python3 patch_reset_fanout_all.py <mycpu_top.v> [输出路径]
"""

import re
import sys


def patch(text: str) -> str:
    lines = text.split("\n")

    # 定位所有 module 区间
    modules = []
    i = 0
    while i < len(lines):
        m = re.match(r"\s*module\s+(\w+)\s*\(", lines[i])
        if m:
            start = i
            j = i + 1
            while j < len(lines):
                if re.match(r"\s*endmodule\s*$", lines[j]):
                    break
                j += 1
            modules.append((start, j, m.group(1)))
            i = j
        i += 1

    patched_modules = []
    # 逆序处理: 每个模块插入 3 行别名, 先改后面的模块可避免行号偏移。
    for start, end, name in reversed(modules):
        mod = lines[start : end + 1]
        # 该模块是否有 aresetn 端口?
        has_port = any(
            re.search(r"^\s*(input|output)\s+(wire\s+|reg\s+)?aresetn\b", ln)
            for ln in mod
        )
        if not has_port:
            continue

        # 找端口列表结束行
        insert_at = None
        for k, ln in enumerate(mod):
            if re.search(r"\)\s*;\s*$", ln):
                insert_at = k + 1
                break
        if insert_at is None:
            raise SystemExit(f"ERROR: port list end not found in module {name}")

        alias = [
            "  (* max_fanout = 200 *) wire aresetn_i;",
            "  assign aresetn_i = aresetn;",
            "",
        ]
        mod[insert_at:insert_at] = alias

        for k, ln in enumerate(mod):
            if "aresetn_i" in ln:
                continue  # 别名行本身 / 已改
            if re.match(r"^\s*(input|output)\s+.*\baresetn\b", ln):
                continue  # 端口声明行
            if "aresetn" in ln:
                mod[k] = re.sub(r"(?<!\.)aresetn", "aresetn_i", ln)

        lines[start : end + 1] = mod
        patched_modules.append(name)

    print(f"patched modules with aresetn port: {len(patched_modules)}")
    for n in patched_modules:
        print(f"  - {n}")
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
