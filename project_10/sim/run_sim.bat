@echo off
REM ===========================================================================
REM run_sim.bat -- prj10 W2 one-click reproduction (xvlog -> xelab -> xsim)
REM Uses ONLY the Vivado simulator batch tools: no Vivado project is created.
REM Run from anywhere; the script cd's to its own directory (ASCII path).
REM Verdict line: "=== prj10 W2 SIM: PASS (0 errors) ==="
REM ===========================================================================
setlocal
set VIV=D:\Xilinx\Vivado\2023.1\bin
cd /d "%~dp0"

if exist xsim.dir rmdir /s /q xsim.dir
del /q xsim_run.log 2>nul

echo === prj10 W2 sim %DATE% %TIME% === > xsim_run.log

call "%VIV%\xvlog.bat" -sv ..\rtl\async_fifo.v ..\rtl\axi4_master_bridge.v ..\rtl\frame_mem_if.v axi4_ram_model.v mem_bridge_tb.sv >> xsim_run.log 2>&1
if errorlevel 1 ( echo XVLOG_FAIL & findstr /C:"ERROR" xsim_run.log & exit /b 1 )

call "%VIV%\xelab.bat" -debug typical mem_bridge_tb -s mem_bridge_sim >> xsim_run.log 2>&1
if errorlevel 1 ( echo XELAB_FAIL & findstr /C:"ERROR" xsim_run.log & exit /b 1 )

call "%VIV%\xsim.bat" mem_bridge_sim -runall >> xsim_run.log 2>&1
set RC=%ERRORLEVEL%
echo XSIM_EXIT=%RC%
findstr /C:"PASS" /C:"FAIL" /C:"SIM:" /C:"STAT " xsim_run.log
exit /b %RC%
