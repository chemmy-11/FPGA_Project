cd D:\FPGA
Remove-Item cleanup.ps1 -Force -ErrorAction SilentlyContinue
git add -A
git commit -q -m '仓库清理: 移除本轮一次性文档修补脚本与临时运行器(17个), 只保留可复现工具(rate_probe.py / pump_stress_tb.v / w6_*.py / regen_ip.tcl 等)'
git log --oneline -4
Write-Output '=== 最终同步核对 ==='
Write-Output ('HEAD   = ' + (git log --oneline -1))
Write-Output ('origin = ' + (git log --oneline -1 origin/master))
Write-Output ('dirty  = ' + (git status --short | Measure-Object).Count)
Write-Output '=== 本轮保留的关键工具 ==='
foreach ($f in @('prj/project_10/prj_loop/scripts/rate_probe.py','prj/project_10/prj_loop/scripts/regen_ip.tcl','prj/project_10/sim/pump_stress_tb.v','prj/project_10/prj_loop/rtl_patch/frame_fifo_pump.v','docs/复现/README.md','docs/复现/prj10_复现指南.md')) { Write-Output ('  ' + (git ls-files $f | Measure-Object).Count + '  ' + $f) }
$env:GIT_TERMINAL_PROMPT='0'; node 'C:\Users\15266\.agents\skills\github-account\scripts\gh.mjs' gittry -C D:\FPGA push origin master 2>&1 | Select-String -Pattern 'master|succeeded|rejected' | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) }
