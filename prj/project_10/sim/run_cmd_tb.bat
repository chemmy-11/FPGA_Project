@echo off
REM ===========================================================================
REM run_cmd_tb.bat -- prj10 W5 cmd_channel unit sim (xvlog / xelab / xsim)
REM   ASCII only (no BOM needed).  Run from anywhere; cd's to its own dir.
REM   1) NEGATIVE CONTROL : elaborated with -generic_top "DEFECT_FIXUP=1"; the
REM      bench then repairs the illegal frames before they reach the DUT, so the
REM      DUT accepts them and the bench MUST report FAIL -- proof that the
REM      negative criteria (wrong port / wrong magic / truncated) are not vacuous.
REM   2) POSITIVE RUN     : plain DUT -> "=== prj10 W5 CMD SIM: PASS (0 errors) ==="
REM   The positive verdict line is appended as the LAST line of cmd_tb.log.
REM ===========================================================================
setlocal
set VIV=D:\Xilinx\Vivado\2023.1\bin
cd /d "%~dp0"

if exist xsim.dir rmdir /s /q xsim.dir
del /q cmd_tb.log cmd_tb_xsim.log cmd_tb_defect_xsim.log cmd_tb_verdict.tmp 2>nul

echo === prj10 W5 cmd_channel unit sim %DATE% %TIME% === > cmd_tb.log

call "%VIV%\xvlog.bat" -sv ..\prj_loop\rtl_patch\cmd_channel.v cmd_channel_tb.sv >> cmd_tb.log 2>&1
if errorlevel 1 ( echo XVLOG_FAIL & findstr /C:"ERROR" cmd_tb.log & exit /b 1 )

REM ---- 1) negative control (defect injection): must FAIL ----
call "%VIV%\xelab.bat" -debug typical cmd_channel_tb -s cmd_tb_defect -generic_top "DEFECT_FIXUP=1" >> cmd_tb.log 2>&1
if errorlevel 1 ( echo XELAB_FAIL_DEFECT & findstr /C:"ERROR" cmd_tb.log & exit /b 1 )
call "%VIV%\xsim.bat" cmd_tb_defect -runall > cmd_tb_defect_xsim.log 2>&1
echo --- NEGATIVE CONTROL (DEFECT_FIXUP=1): the bench must FAIL here --- >> cmd_tb.log
findstr /C:"CMD SIM" /C:"[FAIL]" cmd_tb_defect_xsim.log >> cmd_tb.log
type cmd_tb_defect_xsim.log >> cmd_tb.log

REM ---- 2) positive run (plain DUT): must PASS ----
call "%VIV%\xelab.bat" -debug typical cmd_channel_tb -s cmd_tb_sim >> cmd_tb.log 2>&1
if errorlevel 1 ( echo XELAB_FAIL & findstr /C:"ERROR" cmd_tb.log & exit /b 1 )
call "%VIV%\xsim.bat" cmd_tb_sim -runall > cmd_tb_xsim.log 2>&1
set RC=%ERRORLEVEL%
type cmd_tb_xsim.log >> cmd_tb.log

REM ---- verdict line must be the LAST line of cmd_tb.log ----
findstr /C:"=== prj10 W5 CMD SIM" cmd_tb_xsim.log > cmd_tb_verdict.tmp
type cmd_tb_verdict.tmp >> cmd_tb.log
type cmd_tb_verdict.tmp
echo CMD_TB_EXIT=%RC%
del /q cmd_tb_verdict.tmp 2>nul
exit /b %RC%
