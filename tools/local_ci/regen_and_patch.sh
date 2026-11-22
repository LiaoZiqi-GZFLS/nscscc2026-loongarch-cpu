#!/usr/bin/env bash
# 再生成 + 补丁 + 部署一条龙(代替手工 sbt/copy):
#   sbt "runMain NOP.Main" -> build/mycpu_top.v
#   -> patch_reset_fanout.py(复位扇出复制)
#   -> 拷贝到 src/mycpu/mycpu_top.v(团队提交/流水线拷贝源)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
VIVADO_DIR="$WORKSPACE/T2026143250012561/src/vivado_cannot"

cd "$VIVADO_DIR"
SBT_BAT="/c/Users/Ziqi/AppData/Local/Coursier/data/bin/sbt.bat"
if [ ! -f "$SBT_BAT" ]; then
    echo "ERROR: sbt.bat not found at $SBT_BAT" >&2
    exit 1
fi
"$SBT_BAT" "runMain NOP.Main"
python3 "$SCRIPT_DIR/patch_reset_fanout.py" "$VIVADO_DIR/build/mycpu_top.v" "$WORKSPACE/T2026143250012561/src/mycpu/mycpu_top.v"
echo "regen+patch done: $WORKSPACE/T2026143250012561/src/mycpu/mycpu_top.v"
