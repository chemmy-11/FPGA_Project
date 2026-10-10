@echo off
REM ===========================================================================
REM run_w4_joint.bat -- prj10 W4 one-click JOINT regression (xvlog/xelab/xsim)
REM   1) NEGATIVE control: DEFECT_ROUTING=1 (pre-fix bid/rid-bit routing)
REM      -> must FAIL/deadlock, proving the bench is not vacuous
REM   2) POSITIVE run    : fixed arbiter (grant routing)
REM      -> must print "=== prj10 W4 JOINT SIM: PASS (0 errors) ==="
REM Run from anywhere; the script cd's to its own directory (ASCII path).
REM ===========================================================================
setlocal
set VIV=D:\Xilinx\Vivado\2023.1\bin
cd /d "%~dp0"

if exist xsim.dir rmdir /s /q xsim.dir
del /q w4_joint_run.log 2>nul

echo === prj10 W4 joint sim %DATE% %TIME% === > w4_joint_run.log

call "%VIV%\xvlog.bat" -sv ..\rtl\async_fifo.v ..\rtl\axi4_master_bridge.v ..\rtl\frame_mem_if.v ..\rtl\axi_arb_2to1.v axi4_ram_model.v axi_arb_2to1_defect.v w4_joint_tb.sv >> w4_joint_run.log 2>&1
if errorlevel 1 ( echo XVLOG_FAIL & findstr /C:"ERROR" w4_joint_run.log & exit /b 1 )

REM ---- 1) negative control (defect routing): expect FAIL ----
call "%VIV%\xelab.bat" -debug typical w4_joint_tb -s w4_joint_defect -generic_top "DEFECT_ROUTING=1" >> w4_joint_run.log 2>&1
if errorlevel 1 ( echo XELAB_FAIL_DEFECT & findstr /C:"ERROR" w4_joint_run.log & exit /b 1 )
call "%VIV%\xsim.bat" w4_joint_defect -runall >> w4_joint_run.log 2>&1
echo === NEGATIVE CONTROL (defect routing) ===
findstr /C:"JOINT SIM" /C:"DEADLOCK" /C:"FAIL" w4_joint_run.log

REM ---- 2) positive run (fixed routing): expect PASS ----
call "%VIV%\xelab.bat" -debug typical w4_joint_tb -s w4_joint_fixed >> w4_joint_run.log 2>&1
if errorlevel 1 ( echo XELAB_FAIL_FIXED & findstr /C:"ERROR" w4_joint_run.log & exit /b 1 )
call "%VIV%\xsim.bat" w4_joint_fixed -runall >> w4_joint_run.log 2>&1
set RC=%ERRORLEVEL%
echo === POSITIVE RUN (grant routing) ===
findstr /C:"JOINT SIM" /C:"STAT " /C:"PASS" w4_joint_run.log
echo W4_JOINT_EXIT=%RC%
exit /b %RC%