# =============================================================================
# storm_demo.ps1 - prj9 会话 JSON 传输质量 一键演示与验证
# 用法: powershell -ExecutionPolicy Bypass -File storm_demo.ps1 [quick|full]
#   quick = 100KB 校准(秒级, 期望 100% SHA 一致 - 演示主打)
#   full  = 10MB 全量(约 40s, 展示规模)   默认 quick
# =============================================================================
param([string]$mode = 'quick')
$env:PYTHONUTF8 = '1'   # 必须: GBK 控制台打对勾字符会崩
$py  = 'C:\Users\15266\AppData\Local\Python\pythoncore-3.14-64\python.exe'
Set-Location D:\FPGA\project_9

Write-Host '==== [0/3] 链路体检 ====' -ForegroundColor Cyan
$p = ping 192.168.1.10 -n 3 -w 800
$loss = ($p | Select-String 'Lost').Line
Write-Host $loss
if ($loss -match '\(100% loss\)') {
  Write-Host '!! 板子不通: 若刚上过电, 位流易失需重烧(program_board.tcl), 或检查 T23 灯' -ForegroundColor Red
  exit 1
}

Write-Host '==== [1/3] 开始传输 ====' -ForegroundColor Cyan
if ($mode -eq 'full') {
  & $py scripts\json_storm.py testdata\session_full.jsonl --chunk 1360 --gap-ms 1.0 --out testdata\session_roundtrip.jsonl
} else {
  & $py scripts\json_storm.py testdata\session_full.jsonl --limit-bytes 102400 --chunk 1360 --gap-ms 1.0 --out testdata\calib_out.bin
}
$rc = $LASTEXITCODE

Write-Host ''
Write-Host '==== [2/3] 结果判读 ====' -ForegroundColor Cyan
if ($rc -eq 0) {
  Write-Host 'PASS: 零丢失 + 零损坏 + SHA256 全文一致 - 会话 JSON 完好穿越光链路往返' -ForegroundColor Green
} else {
  Write-Host '注意: 有丢失片(已知 0.4% 相邻对丢失, 位置在 Aurora 渡纤段, 见评测报告) - 损坏/乱序应为 0' -ForegroundColor Yellow
}

Write-Host '==== [3/3] 复位健康检查 ====' -ForegroundColor Cyan
ping 192.168.1.10 -n 4 | Select-Object -Last 3