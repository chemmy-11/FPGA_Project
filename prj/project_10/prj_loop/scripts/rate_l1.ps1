Start-Sleep -Seconds 5
Write-Output '=== 链路体检 ==='
$p = ping 192.168.1.10 -n 5 -w 800 2>&1
($p | Select-String 'Lost').Line
cd D:\FPGA\prj\project_10\prj_loop
$env:PYTHONUTF8=1
Write-Output ''
Write-Output '########## L1 修复后: 帧长 vs 板卡上限 (pace=5us, N=3000) ##########'
foreach ($L in @(128,512,1466)) {
  $o = python scripts\rate_probe.py --n 3000 --pace-us 5 --len $L 2>&1
  $c = ($o | Select-String -Pattern 'PC 发出').Line -replace '^\s+',''
  $a = ($o | Select-String -Pattern '到达内存桥').Line -replace '^\s+',''
  $b = ($o | Select-String -Pattern '入口丢').Line -replace '^\s+',''
  Write-Output "[len=$L] $c"
  Write-Output "          $a"
  Write-Output "          $b"
}
