cd D:\FPGA\prj\project_10\prj_loop
if (Test-Path vivado) { Remove-Item vivado -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output ('vivado 已删: ' + (-not (Test-Path vivado)))
& 'D:\Xilinx\Vivado\2023.1\bin\vivado.bat' -mode batch -source scripts\create_project.tcl -notrace -log recreate3.log -journal recreate3.jou > $null 2>&1
Select-String -Path recreate3.log -Pattern 'CREATE_DONE' | Select-Object -Last 2 | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) }
Write-Output '=== 开始构建 ==='
& 'D:\Xilinx\Vivado\2023.1\bin\vivado.bat' -mode batch -source scripts\build_debug.tcl -notrace -log build_l1_v4.log -journal build_l1_v4.jou > $null 2>&1
Select-String -Path build_l1_v4.log -Pattern 'ram_reg_bram|pump_fwd/ram|pump_rev/ram' | Select-Object -First 4 | ForEach-Object { Write-Output ('  RAM: ' + $_.Line.Trim().Substring(0,[Math]::Min(100,$_.Line.Trim().Length))) }
Select-String -Path build_l1_v4.log -Pattern 'MDRV|multi.?driver' | Select-Object -First 4 | ForEach-Object { Write-Output ('  MDRV: ' + $_.Line.Trim().Substring(0,[Math]::Min(100,$_.Line.Trim().Length))) }
Select-String -Path build_l1_v4.log -Pattern 'TIMING:|WNS_GATE|WHS_GATE|W5_BUILD' | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) }
