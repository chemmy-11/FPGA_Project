cd D:\FPGA\prj\project_10\prj_loop
$env:PYTHONUTF8=1
Write-Output '########## [1] 数据面四档回归(逐字节) ##########'
$o = python scripts\udp_verify_ddr.py 2>&1
$o | Select-String -Pattern 'PASS|FAIL|逐字节一致|到达|DDR_VERIFY' | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) }
Write-Output ''
Write-Output '########## [2] 导师原话验证(正常版) ##########'
$o2 = python scripts\mentor_verify.py 2>&1
$o2 | Select-String -Pattern '板内写计数|逐帧对应|收帧数|缺（|多（|字节差异|J3 |完全正常|引擎判决' | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) }
