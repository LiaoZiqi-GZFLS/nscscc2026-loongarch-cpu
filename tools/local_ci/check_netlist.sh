#!/usr/bin/env bash
# 校验重新生成的 mycpu_top.v:
# 1) 顶层端口列表必须与提交版逐位一致;
# 2) 结构 diff 应只出现在 TLB 查找/调试布线相关区域。
set -euo pipefail

HOME_REPO="D:/code/Vivado/Loongarch_workspace/T2026143250012561"
OLD_NETLIST="$HOME_REPO/src/mycpu/mycpu_top.v"
NEW_NETLIST="$HOME_REPO/src/vivado_cannot/build/mycpu_top.v"

if [ ! -f "$NEW_NETLIST" ]; then
  echo "ERROR: new netlist not found: $NEW_NETLIST" >&2
  exit 1
fi

echo "=== 1) top-level port diff (must be empty) ==="
if diff <(awk '/^module mycpu_top/,/^\);/' "$OLD_NETLIST" | sed 's/[[:space:]]\+/ /g') \
        <(awk '/^module mycpu_top/,/^\);/' "$NEW_NETLIST" | sed 's/[[:space:]]\+/ /g'); then
  echo "PORTS IDENTICAL"
else
  echo "^^^ PORT DIFF FOUND ^^^"
fi

echo
echo "=== 2) structural diff summary ==="
echo "old: $(wc -l < "$OLD_NETLIST") lines, new: $(wc -l < "$NEW_NETLIST") lines"
diff "$OLD_NETLIST" "$NEW_NETLIST" > /tmp/netlist.diff || true
echo "changed line count: $(grep -c '^[<>]' /tmp/netlist.diff)"
echo
echo "=== 3) changed regions: unique signal-name roots (top 30) ==="
grep '^[<>]' /tmp/netlist.diff \
  | sed 's/^[<>] *//' \
  | grep -oE '[A-Za-z_][A-Za-z0-9_]*' \
  | sort | uniq -c | sort -rn | head -30
