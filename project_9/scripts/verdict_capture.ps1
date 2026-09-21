# =============================================================================
# verdict_capture.ps1 - prj9 0.4% 丢失定位判决机（2026-09-21）
# 流程: 三域 ILA 快照(BEFORE) -> 全量传输 -> 快照(AFTER) -> 差分链逐段对账 -> 判决
# 用法: powershell -ExecutionPolicy Bypass -File scripts\verdict_capture.ps1 [full|quick]
#   quick = 100KB 冒烟(验证判决机自身)   full = 10MB 全量(正式判决)  默认 full
# 前提: 板子已上电且重烧判决位流(build9v), T23 常亮
# =============================================================================
param([string]$mode = 'full')
$env:PYTHONUTF8 = '1'
$py  = 'C:\Users\15266\AppData\Local\Python\pythoncore-3.14-64\python.exe'
Set-Location D:\FPGA\project_9

function SnapIlas {
  & 'D:\Xilinx\Vivado\2023.1\bin\vivado.bat' -mode batch -source scripts\ila_cap_cnt.tcl -notrace *> $null
  $s = @{}
  foreach($f in @('ila_cnt0.csv','ila_cnt1.csv','ila_cnt2.csv')){ if(-not (Test-Path ('scripts\\' + $f))){ throw ('ILA 快照缺失: ' + $f + ' - 对应 ILA 抓取失败, 查 build_verdict.log / 板子状态') } }
  $c0 = (Import-Csv scripts\ila_cnt0.csv)[-1]; $c1 = (Import-Csv scripts\ila_cnt1.csv)[-1]; $c2 = (Import-Csv scripts\ila_cnt2.csv)[-1]
  foreach($c in @($c0,$c1,$c2)){ if($c){ foreach($p in $c.PSObject.Properties){ if($p.Name -match '^dbg_'){ $s[$p.Name] = [Convert]::ToInt32(($p.Value -replace '^0x',''),16) } } } }
  return $s
}
function Delta($a,$b,$key){ return ($b[$key] - $a[$key]) }

Write-Host '==== [1/4] BEFORE 快照(三域 ILA) ====' -ForegroundColor Cyan
$B = SnapIlas
if ($B.Count -lt 10) { Write-Host '!! 快照失败: 检查板子上电/重烧(program_board.tcl)' -ForegroundColor Red; exit 1 }
Write-Host ('   pfwd_wr=' + $B['dbg_pfwd_wr[15:0]'] + ' echo_b_tx=' + $B['dbg_echo_b_tx[15:0]'] + ' prev_wr=' + $B['dbg_prev_wr[15:0]'])

Write-Host '==== [2/4] 全量传输 ====' -ForegroundColor Cyan
if ($mode -eq 'quick') {
  & $py scripts\json_storm.py testdata\session_full.jsonl --limit-bytes 102400 --chunk 1360 --gap-ms 1.0 2>&1 | Select-String -Pattern '收到|丢失|损坏' | ForEach-Object { $_.Line }
} else {
  & $py scripts\json_storm.py testdata\session_full.jsonl --chunk 1360 --gap-ms 0.1 2>&1 | Select-String -Pattern '收到|丢失|损坏' | ForEach-Object { $_.Line }
}

Write-Host '==== [3/4] AFTER 快照 ====' -ForegroundColor Cyan
$A = SnapIlas

Write-Host '==== [4/4] 差分判决 ====' -ForegroundColor Cyan
$pcSent = if ($mode -eq 'quick') { 76 } else { 7569 }
$d = @{
  pfwd_wr   = (Delta $B $A 'dbg_pfwd_wr[15:0]')      # 入泵A
  pfwd_rd   = (Delta $B $A 'dbg_pfwd_rd[15:0]')      # 出泵A
  pk_frames = (Delta $B $A 'dbg_pk_frames[15:0]')    # 打包A出(进A.TX)
  eb_rx     = (Delta $B $A 'dbg_echo_b_rx[15:0]')    # B回显入(经纤+ 解包B)
  eb_tx     = (Delta $B $A 'dbg_echo_b_tx[15:0]')    # B回显出(进B.TX)
  up_frames = (Delta $B $A 'dbg_up_frames[15:0]')    # A解包入(经纤回)
  prev_wr   = (Delta $B $A 'dbg_prev_wr[15:0]')      # 泵B入(回PC)
}
$noise = 4   # 快照脚本自带的触发 ping/ARP 噪声(每次快照~2帧全路径)
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
if(($segv | Where-Object { $_ -gt ($noise/2) }).Count -eq 0){ Write-Host '>> 判决: 各段差分为零 - 丢失在栈以前或噪声内, 需复查' -ForegroundColor Yellow }