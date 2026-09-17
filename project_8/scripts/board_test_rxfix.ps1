# board_test_rxfix.ps1 - 烧录 RX 修复版位流并跑全套判据（2026-09-17）
Set-Location D:\FPGA\project_8
& 'D:\Xilinx\Vivado\2023.1\bin\vivado.bat' -mode batch -source scripts\program_board.tcl -notrace |
    Select-String -Pattern 'PROGRAM_OK|DEVICE|ERROR'
Start-Sleep -Seconds 4
ping 192.168.1.10 -n 6
& 'C:\Users\15266\AppData\Local\Python\pythoncore-3.14-64\python.exe' scripts\udp_verify.py
