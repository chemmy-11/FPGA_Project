cd D:\FPGA
git add -A
git status --short | Select-Object -First 8 | ForEach-Object { Write-Output ('  ' + $_) }
git commit -q -m '复现指南补速率验证: prj10 指南新增第9-11步(pace=5us三档探测/PRJ9同款吞吐档/仿真正负对照)含修复前后对照表与判读要点; README 补速率条目+坑#4(报价须盖过被测上限)/#5(RND污染回显测试)'
git log --oneline -1
$env:GIT_TERMINAL_PROMPT='0'; node 'C:\Users\15266\.agents\skills\github-account\scripts\gh.mjs' gittry -C D:\FPGA push origin master 2>&1 | Select-String -Pattern 'master|succeeded|rejected' | ForEach-Object { Write-Output ('  ' + $_.Line.Trim()) }
