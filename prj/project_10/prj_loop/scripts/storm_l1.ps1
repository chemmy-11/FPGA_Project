cd D:\FPGA\prj\project_10\prj_loop
$env:PYTHONUTF8=1
python -c "import py_compile; py_compile.compile(r'scripts\\deadlock_regress.py', doraise=True); print('compile OK')"
Write-Output '=== 恢复 SEQ 后重测 PRJ9 同款吞吐档 ==='
python scripts\cmd_probe.py 01 0 --timeout 2.0 2>&1 | Select-String -Pattern 'PROBE' | ForEach-Object { Write-Output ('  SET_MODE(SEQ): ' + $_.Line.Trim()) }
cd D:\FPGA\prj\project_9
$s = python scripts\json_storm.py testdata\session_full.jsonl --chunk 1466 --pace-us 13 --out out\l1_storm2.jsonl 2>&1
$s | Select-String -Pattern '发送片数|收到片数|丢失片数|损坏片数|到达流逆序对|发送阶段速率|SHA256 比对' | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) }
