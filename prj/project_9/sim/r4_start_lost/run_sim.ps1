# =============================================================================
# run_sim.ps1 - prj9 R4 机制复现一键重跑 (2026-10-01)
# 用法: powershell -ExecutionPolicy Bypass -File run_sim.ps1
# 依赖: Vivado 2023.1 (xvlog/xelab/xsim); 只读 ../..\rtl\udp\udp_tx.v
# 注意: 本文件必须带 UTF-8 BOM (AGENTS.md 坑账本 #17/#18)
# =============================================================================
$ErrorActionPreference = 'Stop'
# PS 5.1 的 > 重定向默认写 UTF-16LE -> 日志既占双倍体积又不可读; 全局改 UTF-8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
Set-Location $PSScriptRoot
$XV = 'D:\Xilinx\Vivado\2023.1\bin'

if (Test-Path xsim.dir) { Remove-Item -Recurse -Force xsim.dir }

Write-Host '[1/3] xvlog ...' -ForegroundColor Cyan
& "$XV\xvlog.bat" r4_tx_start_tb.sv ..\..\rtl\udp\udp_tx.v > compile_out.txt 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host 'xvlog 失败:' -ForegroundColor Red; Get-Content compile_out.txt | Select-Object -Last 15; exit 1 }

Write-Host '[2/3] xelab ...' -ForegroundColor Cyan
& "$XV\xelab.bat" r4_tx_start_tb -s r4sim > elab_out.txt 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host 'xelab 失败:' -ForegroundColor Red; Get-Content elab_out.txt | Select-Object -Last 15; exit 1 }

Write-Host '[3/3] xsim ...' -ForegroundColor Cyan
& "$XV\xsim.bat" r4sim -R > sim_out.txt 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host 'xsim 非零退出:' -ForegroundColor Red; Get-Content sim_out.txt | Select-Object -Last 15; exit 1 }

Write-Host ''
Write-Host '==== 判据输出 ====' -ForegroundColor Green
Get-Content sim_out.txt | Select-String -Pattern 'step|frame|判决|终态' | ForEach-Object { $_.Line }

# 自动判定: R4 成立 = 忙态后帧数不增 且 错位帧载荷为 d0
$t = Get-Content sim_out.txt -Raw
$r4ok = ($t -match '字节流错位【成立】')
Write-Host ''
if ($r4ok) { Write-Host '>> R4 机制: 复现成功 (忙态 start 被丢弃 + 字节流错位)' -ForegroundColor Green; exit 0 }
else { Write-Host '>> R4 机制: 未复现, 需人工判读 sim_out.txt' -ForegroundColor Yellow; exit 2 }
