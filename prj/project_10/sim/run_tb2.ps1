cd D:\FPGA\prj\project_10\sim
$XV='D:\Xilinx\Vivado\2023.1\bin'
$xl = & "$XV\xvlog.bat" -sv pump_stress_tb.v ..\prj_loop\rtl_patch\frame_fifo_pump.v 2>&1
$errs = ($xl | Select-String -Pattern 'ERROR').Count
Write-Output ('xvlog ERROR=' + $errs)
if ($errs -gt 0) { $xl | Select-String -Pattern 'ERROR' | Select-Object -First 4 | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) } }
& "$XV\xelab.bat" -debug typical pump_stress_tb -s ps_l1f > el2.log 2>&1
& "$XV\xsim.bat" ps_l1f -R > rs2.log 2>&1
Select-String -Path rs2.log -Pattern 'RESULT:|PUMP_STRESS:' | ForEach-Object { Write-Output ('RS: ' + $_.Line.Trim()) }
