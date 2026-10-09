cd D:\FPGA\prj\project_10\sim
& 'D:\Xilinx\Vivado\2023.1\bin\xelab.bat' -debug typical pump_stress_tb -s ps_l1e > el.log 2>&1
& 'D:\Xilinx\Vivado\2023.1\bin\xsim.bat' ps_l1e -R > rs.log 2>&1
Select-String -Path el.log -Pattern 'ERROR' | Select-Object -First 3 | ForEach-Object { 'EL: ' + $_.Line.Trim() }
Select-String -Path rs.log -Pattern 'RESULT:|PUMP_STRESS:|ERROR' | ForEach-Object { 'RS: ' + $_.Line.Trim() }