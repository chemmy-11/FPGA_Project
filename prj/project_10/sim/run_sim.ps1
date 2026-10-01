#=============================================================================
# run_sim.ps1 -- prj10 W2: compile + elaborate + run the memory-bridge sim
# Uses ONLY xvlog/xelab/xsim (no Vivado project is created: the draft's red line
# "本单批准前不建工程" is respected literally -- simulation work package only).
# Run from an ASCII path.  Log goes to sim\xsim_run.log
#=============================================================================
# NOTE: Windows execution policy may refuse this file; the primary entry point is
# run_sim.bat (unaffected by the PowerShell policy). If you prefer PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\run_sim.ps1
$ErrorActionPreference = 'Stop'
$viv  = 'D:\Xilinx\Vivado\2023.1\bin'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$log = Join-Path $here 'xsim_run.log'
"=== prj10 W2 sim $(Get-Date -Format s) ===" | Out-File -Encoding utf8 $log

if (Test-Path (Join-Path $here 'xsim.dir')) { Remove-Item -Recurse -Force (Join-Path $here 'xsim.dir') }

& "$viv\xvlog.bat" -sv ..\rtl\async_fifo.v ..\rtl\axi4_master_bridge.v ..\rtl\frame_mem_if.v axi4_ram_model.v mem_bridge_tb.sv *>&1 |
    Tee-Object -FilePath $log -Append
if ($LASTEXITCODE -ne 0) { "XVLOG_FAIL" | Tee-Object -FilePath $log -Append; exit 1 }

& "$viv\xelab.bat" -debug typical mem_bridge_tb -s mem_bridge_sim *>&1 |
    Tee-Object -FilePath $log -Append
if ($LASTEXITCODE -ne 0) { "XELAB_FAIL" | Tee-Object -FilePath $log -Append; exit 1 }

& "$viv\xsim.bat" mem_bridge_sim -runall *>&1 |
    Tee-Object -FilePath $log -Append
"XSIM_EXIT=$LASTEXITCODE" | Tee-Object -FilePath $log -Append
