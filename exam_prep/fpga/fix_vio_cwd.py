import sys

# perf_test_board.bat is UTF-8 (written by us); func_test_board.bat is GBK.
# Both edits are pure-ASCII line replacements -> operate on bytes.

def patch(path, repls):
    with open(path, "rb") as f:
        data = f.read()
    for old, new in repls:
        assert old in data, f"pattern not found in {path}: {old[:60]}"
        data = data.replace(old, new)
    with open(path, "wb") as f:
        f.write(data)
    print("patched:", path)

# ---- perf bat: run vio.tcl with cwd = project dir (official convention) ----
patch(r"D:\code\Vivado\Loogarch_workspace_kimi\exam_prep\fpga\perf_test_board.bat", [
    (
        b'call "%VIVADO%" -mode batch -log vio_perf.log -journal vio_perf.jou -source vio.tcl -tclargs project/loongson.runs/impl_1/soc_top.bit project/loongson.runs/impl_1/soc_top.ltx perf',
        b'cd /d %RUNDV%\\project || goto :fail\r\n'
        b'call "%VIVADO%" -mode batch -log ..\\vio_perf.log -journal ..\\vio_perf.jou -source ..\\vio.tcl -tclargs loongson.runs/impl_1/soc_top.bit loongson.runs/impl_1/soc_top.ltx perf\r\n'
        b'set VIO_RC=%errorlevel%\r\n'
        b'cd /d %RUNDV%'
    ),
    (
        b'call "%VIVADO%" -mode batch -log ..\\vio_perf.log -journal ..\\vio_perf.jou -source ..\\vio.tcl -tclargs loongson.runs/impl_1/soc_top.bit loongson.runs/impl_1/soc_top.ltx perf\r\nset VIO_RC=%errorlevel%\r\ncd /d %RUNDV%\r\nset VIO_RC=%errorlevel%',
        b'call "%VIVADO%" -mode batch -log ..\\vio_perf.log -journal ..\\vio_perf.jou -source ..\\vio.tcl -tclargs loongson.runs/impl_1/soc_top.bit loongson.runs/impl_1/soc_top.ltx perf\r\nset VIO_RC=%errorlevel%\r\ncd /d %RUNDV%'
    ),
    (
        b'if exist perf_vio.csv type perf_vio.csv',
        b'if exist project\\perf_vio.csv type project\\perf_vio.csv'
    ),
])

# ---- func bat (GBK): same cwd fix; lines are pure ASCII ----
patch(r"D:\code\Vivado\Loogarch_workspace_kimi\exam_prep\fpga\func_test_board.bat", [
    (
        b'call "%VIVADO%" -mode batch -log vio_func.log -journal vio_func.jou -source vio.tcl -tclargs project/loongson.runs/impl_1/soc_top.bit project/loongson.runs/impl_1/soc_top.ltx func',
        b'cd /d %RUNDV%\\project || goto :fail\r\n'
        b'call "%VIVADO%" -mode batch -log ..\\vio_func.log -journal ..\\vio_func.jou -source ..\\vio.tcl -tclargs loongson.runs/impl_1/soc_top.bit loongson.runs/impl_1/soc_top.ltx func\r\n'
        b'set VIO_RC=%errorlevel%\r\n'
        b'cd /d %RUNDV%'
    ),
])

# func bat: remove the now-duplicated "set VIO_RC=%errorlevel%" line that
# originally followed the vio call
path = r"D:\code\Vivado\Loogarch_workspace_kimi\exam_prep\fpga\func_test_board.bat"
with open(path, "rb") as f:
    data = f.read()
dup = b'cd /d %RUNDV%\r\nset VIO_RC=%errorlevel%'
if dup in data:
    data = data.replace(dup, b'cd /d %RUNDV%')
    with open(path, "wb") as f:
        f.write(data)
    print("deduped VIO_RC line")

# func bat: func_vio.csv now lands in project/
with open(path, "rb") as f:
    data = f.read()
old = b'if exist func_vio.csv type func_vio.csv'
if old in data:
    data = data.replace(old, b'if exist project\\func_vio.csv type project\\func_vio.csv')
    with open(path, "wb") as f:
        f.write(data)
    print("func csv path fixed")
