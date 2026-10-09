@echo off
REM pump_stress.bat — 帧泵背靠背压力测试 (原版 vs L1)
REM   用法: pump_stress.bat orig   -> 用 prj9 原版泵
REM         pump_stress.bat l1     -> 用 rtl_patch L1 乒乓泵
setlocal
set XV=D:\Xilinx\Vivado\2023.1\bin
cd /d %~dp0
if "%1"=="l1" ( set RTL=..\rtl_patch\frame_fifo_pump.v & set TAG=l1 ) else ( set RTL=..\prj\rtl\frame_fifo_pump.v & set TAG=orig )
del /q xsim.dir\pump_stress* 2>nul
call %XV%\xvlog.bat -sv pump_stress_tb.v %RTL% > pump_stress_%TAG%.log 2>&1
if errorlevel 1 ( echo XVLOG_FAIL & type pump_stress_%TAG%.log & exit /b 1 )
call %XV%\xelab.bat -debug typical pump_stress_tb -s pump_stress_%TAG% >> pump_stress_%TAG%.log 2>&1
if errorlevel 1 ( echo XELAB_FAIL & type pump_stress_%TAG%.log & exit /b 1 )
call %XV%\xsim.bat pump_stress_%TAG% -R >> pump_stress_%TAG%.log 2>&1
findstr /C:"RESULT:" /C:"PUMP_STRESS:" pump_stress_%TAG%.log