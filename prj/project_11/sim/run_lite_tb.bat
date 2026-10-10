@echo off
REM ===========================================================================
REM run_lite_tb.bat -- prj11 B1 axi_lite_regs unit sim (xvlog / xelab / xsim)
REM   ASCII only.  Run from anywhere; cd's to its own dir.
REM   1) NEGATIVE CONTROL : compiled with -d AXI_LITE_REGS_DEFECT (rd_req_pulse
REM      held 2 clocks); the bench MUST report FAIL -- proof that the pulse
REM      width check is not vacuous.
REM   2) POSITIVE RUN     : plain DUT -> "=== prj11 B1 LITE SIM: PASS ==="
REM ===========================================================================
setlocal
set VIV=D:\Xilinx\Vivado\2023.1\bin
cd /d "%~dp0"

del /q lite_tb.log lite_defect.log 2>nul

REM ---- 1) negative control (defect build): must FAIL ----
call "%VIV%\xvlog.bat" -d AXI_LITE_REGS_DEFECT -sv ..\rtl\axi_lite_regs.v axi_lite_regs_tb.sv > lite_defect.log 2>&1
if errorlevel 1 ( echo XVLOG_FAIL_DEFECT & type lite_defect.log & exit /b 1 )
call "%VIV%\xelab.bat" -debug typical axi_lite_regs_tb -s lite_defect >> lite_defect.log 2>&1
if errorlevel 1 ( echo XELAB_FAIL_DEFECT & type lite_defect.log & exit /b 1 )
call "%VIV%\xsim.bat" lite_defect -runall >> lite_defect.log 2>&1
echo --- NEGATIVE CONTROL (defect build): the bench must FAIL here ---
findstr /C:"LITE SIM" /C:"[FAIL]" /C:"[NEG]" lite_defect.log

REM ---- 2) positive run: must PASS (fresh work lib, no defect residue) ----
rmdir /s /q xsim.dir 2>nul
call "%VIV%\xvlog.bat" -sv ..\rtl\axi_lite_regs.v axi_lite_regs_tb.sv > lite_tb.log 2>&1
if errorlevel 1 ( echo XVLOG_FAIL & findstr /C:"ERROR" lite_tb.log & exit /b 1 )
call "%VIV%\xelab.bat" -debug typical axi_lite_regs_tb -s lite_sim >> lite_tb.log 2>&1
if errorlevel 1 ( echo XELAB_FAIL & findstr /C:"ERROR" lite_tb.log & exit /b 1 )
call "%VIV%\xsim.bat" lite_sim -runall >> lite_tb.log 2>&1
set RC=%ERRORLEVEL%
findstr /C:"LITE SIM" /C:"[P" /C:"[FAIL]" lite_tb.log
echo LITE_TB_EXIT=%RC%
exit /b %RC%
