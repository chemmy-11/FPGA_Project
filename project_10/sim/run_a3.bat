@echo off
REM run_a3.bat -- A3 tail-beat WSTRB test at two latency tiers
setlocal
set VIV=D:\Xilinx\Vivado\2023.1\bin
cd /d "%~dp0"
call "%VIV%\xvlog.bat" -sv ..\rtl\async_fifo.v ..\rtl\axi4_master_bridge.v ..\rtl\frame_mem_if.v axi4_ram_model.v a3_tail_tb.sv > a3_xvlog.log 2>&1
if errorlevel 1 ( echo XVLOG_FAIL & type a3_xvlog.log & exit /b 1 )
for %%T in ("0 8 2_9" "198 199 200_200") do (
  for /f "tokens=1,2,3" %%a in (%%T) do (
    call "%VIV%\xelab.bat" -debug typical a3_tail_tb -s a3_sim_%%c -generic_top "W_DLY_T=%%a" -generic_top "AR_LAT_T=%%b" > a3_%%c_xelab.log 2>&1
    if errorlevel 1 ( echo XELAB_FAIL %%c & type a3_%%c_xelab.log ) else (
      call "%VIV%\xsim.bat" a3_sim_%%c -runall > a3_%%c_xsim.log 2>&1
      echo === TIER %%c ===
      findstr /C:"[A3]" /C:"A3 TAIL-WSTRB" a3_%%c_xsim.log
    )
  )
)
exit /b 0