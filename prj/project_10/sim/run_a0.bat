@echo off
REM ============================================================
REM run_a0.bat -- A0: bridge <-> real MIG netlist <-> ddr4_model(8G x16)
REM Step 1: compile+elaborate (this script). Step 2: xsim a0_sim -runall
REM ============================================================
setlocal
set VIV=D:\Xilinx\Vivado\2023.1\bin
set NL=D:\FPGA\prj\project_4\mig_ddr4_cal.cache\ip\2023.1\b\3\b3a7cc3da4aff343
set MD=D:\Xilinx\Vivado\2023.1\data\ip\xilinx\ddr4_v2_2\data\dlib\ultrascale\ddr4_sdram\tb\ddr4_model
set GL=D:\Xilinx\Vivado\2023.1\data\ip\xilinx\ddr4_v2_2\data\dlib\ultrascale\ddr4_sdram\tb
cd /d "%~dp0"

if exist xsim.dir rmdir /s /q xsim.dir

echo [1/4] bridge rtl + A0 tb
call "%VIV%\xvlog.bat" -sv -log a0_v1.log ..\rtl\async_fifo.v ..\rtl\axi4_master_bridge.v ..\rtl\frame_mem_if.v a0_mig_netlist_tb.sv
if errorlevel 1 ( echo XVLOG1_FAIL & exit /b 1 )

echo [2/4] MIG netlist
call "%VIV%\xvlog.bat" -log a0_v2.log -work mig_netlist %NL%\ddr4_0_sim_netlist.v
if errorlevel 1 ( echo XVLOG2_FAIL & exit /b 1 )

echo [3/4] DDR4 model x16 wrapper
call "%VIV%\xvlog.bat" -sv -log a0_v3.log -i "%MD%" -i "%GL%" mig\a0_ddr4_model_wrapper.sv "%GL%\glbl.v"
if errorlevel 1 ( echo XVLOG3_FAIL & exit /b 1 )

echo [4/4] xelab
call "%VIV%\xelab.bat" -log a0_xelab.log -L unisims_ver -L secureip -L work -L mig_netlist -s a0_sim a0_mig_netlist_tb glbl
if errorlevel 1 ( echo XELAB_FAIL & exit /b 1 )

echo === A0 COMPILE OK ===
exit /b 0