@echo off
REM ===========================================================================
REM run_lat_sweep.bat -- A2: latency sweep of the W2 acceptance TB (4 tiers)
REM Tiers target the MEASURED AXI latencies: Lw = 2+W_DLY_T, Lr = 1+AR_LAT_T
REM   tier1 (2,9)     : W_DLY=0   AR_LAT=8    <- must equal the W2 baseline
REM   tier2 (50,50)   : W_DLY=48  AR_LAT=49
REM   tier3 (200,200) : W_DLY=198 AR_LAT=199
REM   tier4 (500,500) : W_DLY=498 AR_LAT=499
REM Output: lat_sweep_summary.txt  (one block per tier)
REM ===========================================================================
setlocal enabledelayedexpansion
set VIV=D:\Xilinx\Vivado\2023.1\bin
cd /d "%~dp0"
del /q lat_sweep_summary.txt 2>nul
del /q lat_t*.log 2>nul

call "%VIV%\xvlog.bat" -sv ..\rtl\async_fifo.v ..\rtl\axi4_master_bridge.v ..\rtl\frame_mem_if.v axi4_ram_model.v mem_bridge_tb.sv > lat_xvlog.log 2>&1
if errorlevel 1 ( echo XVLOG_FAIL & type lat_xvlog.log & exit /b 1 )

for %%T in ("0 8 2 9" "48 49 50 50" "198 199 200 200" "498 499 500 500") do (
  for /f "tokens=1,2,3,4" %%a in (%%T) do (
    set WD=%%a
    set AR=%%b
    set LW=%%c
    set LR=%%d
    echo === TIER Lw=!LW! Lr=!LR! (W_DLY=!WD! AR_LAT=!AR!) === >> lat_sweep_summary.txt
    call "%VIV%\xelab.bat" -debug typical mem_bridge_tb -s lat_sim_!LW! -generic_top "W_DLY_T=!WD!" -generic_top "AR_LAT_T=!AR!" > lat_t!LW!_xelab.log 2>&1
    if errorlevel 1 ( echo XELAB_FAIL >> lat_sweep_summary.txt & type lat_t!LW!_xelab.log >> lat_sweep_summary.txt ) else (
      call "%VIV%\xsim.bat" lat_sim_!LW! -runall > lat_t!LW!_xsim.log 2>&1
      findstr /C:"SIM:" /C:"STAT counters" /C:"STAT axi" /C:"STAT service" /C:"STAT wstrb" /C:"FAIL" lat_t!LW!_xsim.log >> lat_sweep_summary.txt
    )
    echo. >> lat_sweep_summary.txt
  )
)
echo === SWEEP DONE === >> lat_sweep_summary.txt
type lat_sweep_summary.txt
exit /b 0