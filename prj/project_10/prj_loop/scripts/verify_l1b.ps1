cd D:\FPGA\prj\project_10\prj_loop
$env:PYTHONUTF8=1
Write-Output '########## [3] 死锁专项回归 ##########'
$o = python scripts\deadlock_regress.py --n 300 2>&1
$o | Select-String -Pattern 'DEADLOCK_REGRESS|帧量守恒|灌满|读回' | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) }
Write-Output ''
Write-Output '########## [4] PRJ9 同款吞吐档(--pace-us 13, 修复前仅 51.45%) ##########'
cd D:\FPGA\prj\project_9
$s = python scripts\json_storm.py testdata\session_full.jsonl --chunk 1466 --pace-us 13 --out out\l1_storm.jsonl 2>&1
$s | Select-String -Pattern '发送片数|收到片数|丢失片数|损坏片数|到达流逆序对|发送阶段速率|SHA256 比对' | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) }
