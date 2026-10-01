<#
================================================================================
阶段二之十_prj9_E1E5执行_2026-09-29.ps1
prj9 传输效率实验 E1-E5 一键执行(PC 侧)
================================================================================
对应文档:
  操作文档/阶段二之十_prj9_传输效率与瓶颈判定实操单_2026-09-29.md   (§五 实验矩阵 / §七 判据)
  调试记录/阶段二之十_prj9_json_storm改造与E1E5执行前置记录_2026-09-29.md (§四 命令口径 / §6.4 E3 验证法)

用法:
  powershell -ExecutionPolicy Bypass -File <本脚本> -DryRun     # 只打印将执行的命令: 不发一帧/不 ping/不启动 Vivado
  powershell -ExecutionPolicy Bypass -File <本脚本>             # 跑 E1 + E2 + E3
  powershell -ExecutionPolicy Bypass -File <本脚本> -Stage e3   # 只跑 E3
  powershell -ExecutionPolicy Bypass -File <本脚本> -RunE5      # 附加 E5(会启动 Vivado 抓 ILA)

前提(物理层归用户, AGENTS.md 红线 #2):
  板子上电 + 判决位流 build9v/w 已烧 + T23 常亮 + 光纤已插好
  实验纪律: 不 ping 板卡(本脚本的体检 ping 用 -NoPing 关闭)、arp -d 后立即开测、
            关闭多余网卡协议(NetBIOS/mDNS) —— 避开 R3(FIFO 溢出不可见)
红线: 本脚本不烧录、不动 rtl/prj/xdc; 仅 -RunE5 时会启动 Vivado(单实例)
================================================================================
#>
# ---------------------------------------------------------------------------
# 【本目录约定 · BOM 是硬要求】本目录的 .ps1 必须存为 UTF-8 带 BOM。
#   原因: 本机 PowerShell 是 5.1 Desktop, 读无 BOM 的 .ps1 会按 ANSI(CP936) 解码,
#   中文串的 UTF-8 字节会吞掉紧跟其后的单引号 -> 语法错误, powershell -File 直接报错。
#   verdict_capture.ps1 曾因此从未成功执行过 —— 见
#   阶段二之十_prj9_json_storm改造与E1E5执行前置记录_2026-09-29.md 5.7 节。
#   本文件已带 BOM(前 3 字节 EF BB BF)。修改后请复核: 前 3 字节 = 239 187 191。
#   复核:  $b=[IO.File]::ReadAllBytes(<本文件>); $b[0..2] -join ' '
# ---------------------------------------------------------------------------
param(
  [ValidateSet('all','e1','e2','e3')][string]$Stage = 'all',
  [int]$Chunk = 1466,
  [int]$LimitBytes = 10485760,
  [switch]$DryRun,
  [switch]$NoPing,
  [switch]$RunE5
)
$ErrorActionPreference = 'Stop'
$env:PYTHONUTF8 = '1'                     # 必须: GBK 控制台打对勾字符会崩
$py   = 'C:\Users\15266\AppData\Local\Python\pythoncore-3.14-64\python.exe'
$root = 'D:\FPGA\project_9'
$src  = 'testdata\session_full.jsonl'
Set-Location $root
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$logDir = Join-Path $root ('out\e1e5_logs_' + $stamp)
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$results = @()

function Rule($t){ Write-Host ''; Write-Host ('==== ' + $t + ' ====') -ForegroundColor Cyan }

# ---------------------------------------------------------------- [0] 前置
Rule '[0] 前置检查'
if (-not (Test-Path $py))  { Write-Host ('!! 找不到 python: ' + $py) -ForegroundColor Red;  exit 3 }
if (-not (Test-Path $src)) { Write-Host ('!! 找不到负载: ' + $src) -ForegroundColor Red; exit 3 }
$nChunk = [math]::Ceiling((Get-Item $src).Length / $Chunk)
Write-Host ('python  : ' + $py)
Write-Host ('负载    : ' + $src + '  ' + (Get-Item $src).Length + ' B  ->  chunk ' + $Chunk + ' = ' + $nChunk + ' 片')
Write-Host ('日志    : ' + $(if ($DryRun) { '(DryRun: 不产生日志)' } else { $logDir }))
Write-Host ('物理前提: 板子上电 + build9v/w 已烧 + T23 常亮 + 光纤已插(本脚本不校验, 归用户)') -ForegroundColor Yellow
if ($DryRun) { Write-Host 'DryRun: 只打印命令, 不发一帧、不 ping、不启动 Vivado' -ForegroundColor Yellow }

# ---------------------------------------------------------------- [1] 体检
if (-not $DryRun -and -not $NoPing) {
  Rule '[1] 链路体检'
  $p  = ping 192.168.1.10 -n 3 -w 800
  $ok = ($p | Select-String -Pattern 'TTL=').Count
  Write-Host ('ping 回包: ' + $ok + '/3')
  if ($ok -eq 0) {
    Write-Host '!! 板子不通: 若刚上过电, 位流易失需重烧(program_board.tcl), 或检查 T23 灯' -ForegroundColor Red
    exit 1
  }
} else { Rule '[1] 链路体检(已跳过)' }

# ---------------------------------------------------------------- 工具函数
function Invoke-Storm {
  param([string]$Tag, [string[]]$Extra)
  $argv = @('scripts\json_storm.py', $src) + $Extra
  Rule ($Tag + ' 执行')
  Write-Host ('& $py ' + ($argv -join ' ')) -ForegroundColor Gray
  if ($DryRun) { return $null }
  $log = Join-Path $logDir ($Tag + '.log')
  $out = & $py @argv 2>&1
  $out | Tee-Object -FilePath $log | ForEach-Object { $_ }
  return $out
}
function Get-Summary($out) {
  if (-not $out) { return $null }
  $line = ($out | Select-String -Pattern 'JSON_STORM_SUMMARY:').Line
  if (-not $line) { Write-Host '!! 未取得 JSON_STORM_SUMMARY(传输异常?)' -ForegroundColor Red; return $null }
  $o = @{}
  foreach ($k in @('chunks','recv','lost','corrupt','sha_match','chunk_size','goodput_send_mbps','pace_us','pace_late','pace_iv_avg_us')) {
    if ($line -match ('"' + $k + '":\s*([^,}]+)')) { $o[$k] = $Matches[1].Trim() }
  }
  $o['_line'] = $line
  return $o
}
function Show-Judge {
  param([string]$Tag, $sum, $out)
  if (-not $sum) { return }
  $recv = [int]$sum['recv']; $n = [int]$sum['chunks']; $lost = [int]$sum['lost']
  $rate = [double]$sum['goodput_send_mbps']; $sha = $sum['sha_match']
  $pct  = if ($n -gt 0) { [math]::Round(100.0 * $recv / $n, 2) } else { 0 }
  Write-Host ''
  Write-Host ('--- ' + $Tag + ' 判读 ---') -ForegroundColor Green
  Write-Host ('到达 ' + $recv + '/' + $n + ' (' + $pct + '%)   丢失 ' + $lost + '   损坏 ' + $sum['corrupt'] + '   SHA一致 ' + $sha + '   发送速率 ' + [math]::Round($rate,1) + ' Mbps')
  if ($rate -gt 0) { Write-Host ('单帧耗时 ≈ ' + [math]::Round($Chunk * 8.0 / $rate, 2) + ' µs  (chunk*8/rate)') }
  foreach ($pat in @('节拍实测','突发检查','判定','含预构造速率')) {
    $l = ($out | Select-String -Pattern $pat).Line
    if ($l) { Write-Host ('  ' + $l) }
  }
  switch ($Tag) {
    'E1' {
      if ($sha -eq 'true') { Write-Host '  E-E1: 通过(100% + SHA256 一致)' -ForegroundColor Green }
      else { Write-Host '  E-E1: 未通过(有丢失/损坏) -> 按实操单 §四 风险清单对照 R1/R3/R4' -ForegroundColor Yellow }
      if ($rate -gt 0) {
        $pf = $Chunk * 8.0 / $rate
        Write-Host ''
        Write-Host '  --- E3 可达性预判(由 E1 定标, 判据 §6.4) ---' -ForegroundColor Cyan
        if ($pf -le 11)       { Write-Host ('  单帧 ' + [math]::Round($pf,2) + ' µs <= 11 -> E3(12.5µs) 有余量, 大概率达标') -ForegroundColor Green }
        elseif ($pf -le 12.3) { Write-Host ('  单帧 ' + [math]::Round($pf,2) + ' µs 在 11-12.3 临界区 -> 看 E3 的 节拍实测/判定 两行') -ForegroundColor Yellow }
        else                  { Write-Host ('  单帧 ' + [math]::Round($pf,2) + ' µs > 12.3 -> E3 会被 sendto 顶穿: pacer 形同虚设, 届时速率是 PC 上限而非设定值, 触发 B2(C 发包器)评估') -ForegroundColor Red }
      }
    }
    'E2' {
      Write-Host '  E-E2: 看到达率 >=97% 且 板端 dbg_prev_drop+dbg_pfwd_drop 与 PC 丢失数算术闭合(±1); dbg_pfwd_stuck_cnt 必须 = 0' -ForegroundColor Yellow
    }
    'E3' {
      $cmdBits = ($out | Select-String -Pattern '判定').Line
      if ($sha -eq 'true' -and $rate -ge 900 -and $cmdBits -match '节拍有效') {
        Write-Host '  E-E3: 达标(>=900 Mbps 且 100%+SHA256; 板端 dbg_prev_drop 需 ILA 复核=0)' -ForegroundColor Green
      } else {
        Write-Host '  E-E3: 未达标或需复核 -> 若 判定 行为 "pacer 形同虚设", 归因 PC 侧(三问①证据) 而非硬件' -ForegroundColor Yellow
      }
    }
  }
}

# ---------------------------------------------------------------- 实验体
$E1Args = @('--gap-ms','0','--chunk',"$Chunk",'--limit-bytes',"$LimitBytes",'--out','out\recv_e1.bin')
$E2Args = @('--gap-ms','0','--chunk',"$Chunk",'--parallel','4','--limit-bytes',"$LimitBytes",'--out','out\recv_e2.bin')
$E3Args = @('--pace-us','12.5','--chunk',"$Chunk",'--limit-bytes',"$LimitBytes",'--out','out\recv_e3.bin')

if ($Stage -in @('all','e1')) {
  $o = Invoke-Storm 'E1' $E1Args; $s = Get-Summary $o; Show-Judge 'E1' $s $o
  if ($s) { $results += [pscustomobject]@{ Tag='E1'; Mbps=[math]::Round([double]$s['goodput_send_mbps'],1); Recv=('' + $s['recv'] + '/' + $s['chunks']); SHA=$s['sha_match'] } }
}
if ($Stage -in @('all','e2')) {
  Rule 'E2 提示: 4 进程背靠背是过载场景, 可能触发板端硬冻结(实操单 §十 风险 1)'
  Write-Host '建议: E2 单独排期, 不与 D 线实验同日; 冻结即抓 dbg_pfwd_stuck_cnt' -ForegroundColor Yellow
  $o = Invoke-Storm 'E2' $E2Args; $s = Get-Summary $o; Show-Judge 'E2' $s $o
  if ($s) { $results += [pscustomobject]@{ Tag='E2'; Mbps=[math]::Round([double]$s['goodput_send_mbps'],1); Recv=('' + $s['recv'] + '/' + $s['chunks']); SHA=$s['sha_match'] } }
}
if ($Stage -in @('all','e3')) {
  $o = Invoke-Storm 'E3' $E3Args; $s = Get-Summary $o; Show-Judge 'E3' $s $o
  if ($s) { $results += [pscustomobject]@{ Tag='E3'; Mbps=[math]::Round([double]$s['goodput_send_mbps'],1); Recv=('' + $s['recv'] + '/' + $s['chunks']); SHA=$s['sha_match'] } }
}

# ---------------------------------------------------------------- [4] E5
if ($RunE5) {
  Rule '[4] E5 六段差分链对账'
  Write-Host '!! E5 会启动 Vivado 抓 ILA(单实例): 确认无其他 Vivado 任务在跑' -ForegroundColor Yellow
  Write-Host '   E5 自身用 --chunk 1360 --gap-ms 0.1(口径对账, 非线速实验); 其 发送片数/PC丢失 自动读自 SUMMARY' -ForegroundColor Yellow
  if ($DryRun) {
    Write-Host '& powershell -ExecutionPolicy Bypass -File scripts\verdict_capture.ps1 full' -ForegroundColor Gray
  } else {
    & powershell -ExecutionPolicy Bypass -File scripts\verdict_capture.ps1 full
    Write-Host ('E5 exit = ' + $LASTEXITCODE)
  }
} else { Rule '[4] E5 未执行(需显式 -RunE5)' }

# ---------------------------------------------------------------- 汇总
if (-not $DryRun -and $results.Count -gt 0) {
  Rule '汇总'
  $results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
  Write-Host ('日志目录: ' + $logDir)
  Write-Host '下一步: E4 用 Wireshark(过滤 udp.port==1234)独立测回程; 判定报告按实操单 §八 三问模板填数' -ForegroundColor Cyan
}
Write-Host ''
Write-Host '完成。口径提醒: 以上数字全部是**上板实测**; 与"静态预算 953/957-959 Mbps"和"PC 单进程上限"三种口径不可混用。' -ForegroundColor Cyan
