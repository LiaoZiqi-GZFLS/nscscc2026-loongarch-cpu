@echo off
rem ============================================================
rem  NOP-Core 断网重建网表（2026 龙芯杯决赛指令集答题专用）
rem  前置：JDK17 + exam_prep\tools\sbt-launch-1.9.9.jar + coursier 缓存
rem  已验证：COURSIER_MODE=offline 下 40 秒完成，产物与提交网表等价
rem ============================================================
setlocal
set COURSIER_MODE=offline
set JAVA_EXE=C:\Program Files\Java\jdk-17\bin\java.exe
set SBT_JAR=D:\code\Vivado\Loogarch_workspace_kimi\exam_prep\tools\sbt-launch-1.9.9.jar
set PROJ=D:\code\Vivado\Loogarch_workspace_kimi\t26-perf-submit-trio\src\vivado_cannot

cd /d %PROJ%
"%JAVA_EXE%" --add-opens java.base/java.lang=ALL-UNNAMED ^
  --add-opens java.base/java.util=ALL-UNNAMED ^
  --add-opens java.base/java.lang.reflect=ALL-UNNAMED ^
  -jar "%SBT_JAR%" "runMain NOP.Main"

if errorlevel 1 (
  echo [FAIL] sbt elaborate failed
  exit /b 1
)

copy /y "%PROJ%\build\mycpu_top.v" "%PROJ%\..\mycpu\mycpu_top.v"
if errorlevel 1 (
  echo [FAIL] copy mycpu_top.v failed
  exit /b 1
)
echo [OK] mycpu_top.v regenerated and copied to src\mycpu\
endlocal
