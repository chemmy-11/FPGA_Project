cd D:\FPGA\prj\project_10\prj_loop
$env:PYTHONUTF8=1
Write-Output '########## 异常报错版(负向对照) ##########'
$o = python scripts\mentor_verify.py --mode fault 2>&1
$o | Select-String -Pattern '报错内容|判定：|异常报错版：|引擎判决' | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) }
Write-Output ''
Write-Output '########## 连跑 3 次稳定性 ##########'
foreach ($i in 1..3) {
  $o2 = python scripts\mentor_verify.py 2>&1
  $f = ($o2 | Select-String -Pattern '逐帧对应').Line -replace '^\s+',''
  $v = ($o2 | Select-String -Pattern '引擎判决').Line -replace '^\s+',''
  Write-Output "  run $i : $f | $v"
}
