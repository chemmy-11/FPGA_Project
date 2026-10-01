# =============================================================================
# verdict_capture.ps1 - prj9 0.4% 丢失定位判决机（2026-09-21）
# 流程: 三域 ILA 快照(BEFORE) -> 全量传输 -> 快照(AFTER) -> 差分链逐段对账 -> 判决
# 用法: powershell -ExecutionPolicy Bypass -File scripts\verdict_capture.ps1 [full|quick]
#   quick = 100KB 冒烟(验证判决机自身)   full = 10MB 全量(正式判决)  默认 full
# 前提: 板子已上电且重烧判决位流(build9v), T23 常亮
# 留档(2026-10-01): 每次快照的 ila_cntN.csv 自动归档到 scripts\ila_archive\<runId>\<stage>\,
#   固定名文件照旧生成(供本脚本读取), 归档副本可提交为判据证据
# =============================================================================
param([string]$mode = 'full', [int]$PcLost = -1)
$env:PYTHONUTF8 = '1'
$py  = 'C:\Users\15266\AppData\Local\Python\pythoncore-3.14-64\python.exe'
Set-Location D:\FPGA\prj\project_9
# ---- 配对留档(2026-10-01) -----------------------------------------------------
# 为什么: ila_cap_cnt.tcl 用 write_hw_ila_data -force 写固定名 ila_cntN.csv, 每次快照覆盖
#   前一次, 且 .gitignore:66 忽略它们 -> BEFORE/AFTER 配对在 09-21 已丢失, 六段对账
#   至今不可独立重算(体检报告 §5.6 / json_storm 改造记录 §七-5)。留档后每次 E5 的
#   配对产物落在 ila_archive\<runId>\{BEFORE,AFTER}\, 不被覆盖且 git 可追踪。
$runId    = Get-Date -Format 'yyyyMMdd_HHmmss'
$archRoot = 'scripts\ila_archive\' + $runId

function SnapIlas([string]$stage) {
  & 'D:\Xilinx\Vivado\2023.1\bin\vivado.bat' -mode batch -source scripts\ila_cap_cnt.tcl -notrace *> $null
  $s = @{}
  foreach($f in @('ila_cnt0.csv','ila_cnt1.csv','ila_cnt2.csv')){ if(-not (Test-Path ('scripts\\' + $f))){ throw ('ILA 快照缺失: ' + $f + ' - 对应 ILA 抓取失败, 查 build_verdict.log / 板子状态') } }
  $c0 = (Import-Csv scripts\ila_cnt0.csv)[-1]; $c1 = (Import-Csv scripts\ila_cnt1.csv)[-1]; $c2 = (Import-Csv scripts\ila_cnt2.csv)[-1]
  foreach($c in @($c0,$c1,$c2)){ if($c){ foreach($p in $c.PSObject.Properties){ if($p.Name -match '^dbg_'){ $s[$p.Name] = [Convert]::ToInt32(($p.Value -replace '^0x',''),16) } } } }
  # 配对留档: 本阶段三份 CSV 复制到 ila_archive\<runId>\<stage>\; 固定名原件供上面的 Import-Csv 用
  $stageDir = Join-Path $archRoot $stage
  New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
  foreach($f in @('ila_cnt0.csv','ila_cnt1.csv','ila_cnt2.csv')){ Copy-Item ('scripts\' + $f) -Destination $stageDir -Force }
  $mf = @(('stage=' + $stage), ('mode=' + $mode), ('time=' + (Get-Date -Format s)), '')
  foreach($k in ($s.Keys | Sort-Object)){ $mf += ($k + '=' + $s[$k]) }
  Set-Content -Path (Join-Path $stageDir 'manifest.txt') -Value ($mf -join "`r`n") -Encoding UTF8
  Write-Host ('   [留档] ' + $stageDir + ' (3 CSV + manifest.txt)')
  return $s
}
function Delta($a,$b,$key){ return ($b[$key] - $a[$key]) }

Write-Host '==== [1/4] BEFORE 快照(三域 ILA) ====' -ForegroundColor Cyan
$B = SnapIlas 'BEFORE'
if ($B.Count -lt 10) { Write-Host '!! 快照失败: 检查板子上电/重烧(program_board.tcl)' -ForegroundColor Red; exit 1 }
Write-Host ('   pfwd_wr=' + $B['dbg_pfwd_wr[15:0]'] + ' echo_b_tx=' + $B['dbg_echo_b_tx[15:0]'] + ' prev_wr=' + $B['dbg_prev_wr[15:0]'])

Write-Host '==== [2/4] 全量传输 ====' -ForegroundColor Cyan
if ($mode -eq 'quick') {
  $out = & $py scripts\json_storm.py testdata\session_full.jsonl --limit-bytes 102400 --chunk 1466 --gap-ms 1.0 2>&1
} else {
  $out = & $py scripts\json_storm.py testdata\session_full.jsonl --chunk 1466 --gap-ms 0.1 2>&1
}
$out | Select-String -Pattern '收到|丢失|损坏' | ForEach-Object { $_.Line }
# PC 侧口径自动读取(2026-09-29 修复): 取代硬编码 7569/76 —— chunk 一改就会错, 且读不到必须报错而不能默认
$sum = ($out | Select-String -Pattern 'JSON_STORM_SUMMARY:').Line
if (-not $sum) { Write-Host '!! 未取得 JSON_STORM_SUMMARY —— E5 对账需要 PC 侧发/收数, 拒绝用硬编码默认值继续' -ForegroundColor Red; exit 2 }
if ($sum -match '"chunks":\s*(\d+)') { $pcSent = [int]$Matches[1] } else { Write-Host '!! SUMMARY 缺 "chunks" 字段' -ForegroundColor Red; exit 2 }
if ($sum -match '"lost":\s*(\d+)')   { $PcLost = [int]$Matches[1] } else { Write-Host '!! SUMMARY 缺 "lost" 字段'   -ForegroundColor Red; exit 2 }
Write-Host ('  PC 口径(自动读取): 发送片数=' + $pcSent + '  PC 丢失=' + $PcLost)

Write-Host '==== [3/4] AFTER 快照 ====' -ForegroundColor Cyan
$A = SnapIlas 'AFTER'

Write-Host '==== [4/4] 差分判决 ====' -ForegroundColor Cyan
$d = @{
  pfwd_wr   = (Delta $B $A 'dbg_pfwd_wr[15:0]')      # 入泵A
  pfwd_rd   = (Delta $B $A 'dbg_pfwd_rd[15:0]')      # 出泵A
  pk_frames = (Delta $B $A 'dbg_pk_frames[15:0]')    # 打包A出(进A.TX)
  eb_rx     = (Delta $B $A 'dbg_echo_b_rx[15:0]')    # B回显入(经纤+ 解包B)
  eb_tx     = (Delta $B $A 'dbg_echo_b_tx[15:0]')    # B回显出(进B.TX)
  up_frames = (Delta $B $A 'dbg_up_frames[15:0]')    # A解包入(经纤回)
  prev_wr   = (Delta $B $A 'dbg_prev_wr[15:0]')      # 泵B入(回PC)
}
$noise = 4   # 经验值; 若 quick 模式复核噪声基线 != 4 则按实测改
#              (快照脚本自带触发 ping/ARP 噪声, 每次快照约 2 帧走全路径)
Write-Host ('  入泵A    pfwd_wr  +' + $d.pfwd_wr   + '  (PC发' + $pcSent + ', 差=' + ($d.pfwd_wr - $pcSent - $noise) + ' 噪声/栈丢)')
Write-Host ('  出泵A    pfwd_rd  +' + $d.pfwd_rd   + '   泵A内部丢=' + ($d.pfwd_wr - $d.pfwd_rd))
Write-Host ('  打包A出  pk_frames+' + $d.pk_frames + '   打包A丢=' + ($d.pfwd_rd - $d.pk_frames))
Write-Host ('  B回显入  eb_rx    +' + $d.eb_rx     + '   A.TX->纤->B.RX 段丢=' + ($d.pk_frames - $d.eb_rx))
Write-Host ('  B回显出  eb_tx    +' + $d.eb_tx     + '   B回显内部丢=' + ($d.eb_rx - $d.eb_tx))
Write-Host ('  A解包入  up_frames+' + $d.up_frames + '   B.TX->纤->A.RX 段丢=' + ($d.eb_tx - $d.up_frames))
Write-Host ('  泵B入    prev_wr  +' + $d.prev_wr   + '   泵B/栈丢=' + ($d.up_frames - $d.prev_wr))
Write-Host ('  溢出/错误计数: pk_ovf=' + (Delta $B $A 'dbg_pk_ovf_cnt[15:0]') + ' eb_ovf=' + (Delta $B $A 'dbg_echo_b_ovf_cnt[15:0]') + ' hard_err=' + (Delta $B $A 'dbg_hard_err_cnt[15:0]') + '/' + (Delta $B $A 'dbg_hard_err_b_cnt[15:0]') + ' soft_err=' + (Delta $B $A 'dbg_soft_err_cnt[15:0]') + '/' + (Delta $B $A 'dbg_soft_err_b_cnt[15:0]') + ' 断链=' + (Delta $B $A 'dbg_ch_up_evt[15:0]') + '/' + (Delta $B $A 'dbg_ch_up_b_evt[15:0]') + ' 泵A楔死=' + (Delta $B $A 'dbg_pfwd_stuck_cnt[15:0]'))
$seg = @('泵A内部','打包A','A.TX->纤->B.RX','B回显内部','B.TX->纤->A.RX','泵B/栈')
$segv = @(($d.pfwd_wr-$d.pfwd_rd),($d.pfwd_rd-$d.pk_frames),($d.pk_frames-$d.eb_rx),($d.eb_rx-$d.eb_tx),($d.eb_tx-$d.up_frames),($d.up_frames-$d.prev_wr))
Write-Host ''
for($i=0;$i -lt 6;$i++){ if($segv[$i] -gt ($noise/2)){ Write-Host ('>> 判决: 丢失主要落在 [' + $seg[$i] + '] 段, 约 ' + $segv[$i] + ' 帧') -ForegroundColor Green } }
if(($segv | Where-Object { $_ -gt ($noise/2) }).Count -eq 0){ if($PcLost -eq 0){ Write-Host '>> 判决: 全链零丢失(各段差分为零) - 完美往返' -ForegroundColor Green } elseif($PcLost -gt 0){ Write-Host '>> 判决: 各段差分为零但 PC 有丢失 - 丢失在栈以前, 需复查' -ForegroundColor Yellow } else { Write-Host '>> 判决: 全链零丢失(各段差分为零)' -ForegroundColor Green } }
