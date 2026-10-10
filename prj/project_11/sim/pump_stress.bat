@echo off
REM pump_stress.bat - frame pump back-to-back stress (orig vs L1)
REM   usage: pump_stress.bat orig  -> prj9 original pump (frozen baseline)
REM          pump_stress.bat l1    -> L1 ping-pong pump (prj11/rtl)
setlocal
set XV=D:\Xilinx\Vivado\2023.1\bin
cd /d %~dp0
if "%1"=="l1" goto l1
set RTL=D:\FPGA\prj\project_9\rtl\frame_fifo_pump.v
set TAG=orig
goto run
:l1
set RTL=..\rtl\frame_fifo_pump.v
set TAG=l1
:run
del /q xsim.dir\pump_stress* 2>nul
call %XV%\xvlog.bat -sv pump_stress_tb.v %RTL% > pump_stress_%TAG%.log 2>&1
if errorlevel 1 ( echo XVLOG_FAIL & type pump_stress_%TAG%.log & exit /b 1 )
call %XV%\xelab.bat -debug typical pump_stress_tb -s pump_stress_%TAG% >> pump_stress_%TAG%.log 2>&1
if errorlevel 1 ( echo XELAB_FAIL & type pump_stress_%TAG%.log & exit /b 1 )
call %XV%\xsim.bat pump_stress_%TAG% -R >> pump_stress_%TAG%.log 2>&1
findstr /C:"RESULT:" /C:"PUMP_STRESS:" pump_stress_%TAG%.log
