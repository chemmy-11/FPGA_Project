$V='C:\Users\15266\Desktop\毕设'; $D='D:\FPGA\docs'
Copy-Item "$V\调试记录\阶段三_prj10_速率瓶颈诊断与L2写路径流水化_2026-10-09.md" "$D\调试记录\" -Force
Copy-Item "$V\agent.md" "$D\agent.md" -Force
Copy-Item "$V\追踪_cross_短期待办_2026-08-03.md" "$D\追踪_cross_短期待办_2026-08-03.md" -Force
Copy-Item "$V\操作文档\阶段三_prj10_W5随机读上板验证单_2026-10-07.md" "$D\操作文档\" -Force
Write-Output 'mirrored'
cd D:\FPGA
git add -A
git add -f prj/project_10/prj_loop/out/archive/w6_l1_pingpong_2026-10-09.bit prj/project_10/prj_loop/out/archive/w6_l1_pingpong_2026-10-09.ltx
git commit -q -m 'L1 帧泵乒乓双bank 速率修复上板收敛: 1466B 41.7k->82.67k fps 零丢帧(≈969 Mbps 线速), PRJ9吞吐档 51.45%->99.99%; 功能回归全过(DDR四档/导师原话正常+报错/死锁专项/稳定性3-3); WNS +0.019; 位流 DBE35734 已归档; 坑账本#31-34'
git log --oneline -1
$env:GIT_TERMINAL_PROMPT='0'; node 'C:\Users\15266\.agents\skills\github-account\scripts\gh.mjs' gittry -C D:\FPGA push origin master 2>&1 | Select-String -Pattern 'master|succeeded|rejected' | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) }
