# -*- coding: utf-8 -*-
import io
BT = chr(96)
P = r'C:\Users\15266\Desktop\毕设\操作文档\阶段三_prj10_W4两级内存联调上板验证单_2026-10-07.md'
s = io.open(P, encoding='utf-8').read()

old_head = '## 第 5 步：10MB 全量 SHA（J4-4）\n\n**操作**：\n\n~~~powershell\n$env:PYTHONUTF8 = 1\ncd D:\\FPGA\\prj\\project_9\npython scripts\\json_storm.py testdata\\session_full.jsonl --pace-us 13 --out out\\w4j4_重组.jsonl\n~~~'
new_head = ('## 第 5 步：10MB 全量 SHA（J4-4）\n\n'
  '> ⚠️ **2026-10-07 实测订正（重要）**：本步用**质量档（默认 1ms 间隔）**——' + BT + '--pace-us 13' + BT + ' 属 **E2/E3 类吞吐档**，'
  '实测会打满入口（泵A 单帧在途忙丢约 51%，见下方“吞吐档（可选）”）。首版验证单误把 pace13 写成完整性档，已订正。\n\n'
  '**操作（完整性判据 · 质量档）**：\n\n~~~powershell\n$env:PYTHONUTF8 = 1\ncd D:\\FPGA\\prj\\project_9\n'
  'python scripts\\json_storm.py testdata\\session_full.jsonl --out out\\w4j4_quality.jsonl\n~~~')
assert old_head in s, 'step5 head anchor not found'
s = s.replace(old_head, new_head, 1)

anchor = '## 失败处置判读表（按现象查，一行一个处置）'
storm = ('## 吞吐档（可选 · 非 J4 判据）：pace 13µs 冲击观测\n\n'
  '**操作**：\n\n~~~powershell\n$env:PYTHONUTF8 = 1\ncd D:\\FPGA\\prj\\project_9\n'
  'python scripts\\json_storm.py testdata\\session_full.jsonl --pace-us 13 --out out\\w4j4_storm.jsonl\n~~~\n\n'
  '**实测口径（2026-10-07，勿误读）**：收到约 **51%**（3612/7022）、**损坏 0 / 乱序 0 / 板子不冻结**；'
  '丢失全部发生在**泵A 之前**（入口 ' + BT + 'pfwd_drop' + BT + ' 3402 ≈ PC 丢失 3410 − 泵B 丢 8），'
  '**两座内存桥零丢零错**。这是 prj9 已知的“泵A 单帧在途”结构特性（D2 描述符环解决），**不是 J4 完整性判据**；'
  '完整性看第 5 步质量档（100% + SHA 一致）。\n\n'
  '**判据（若跑）**：损坏 0、乱序 0、板子不冻结（ping 仍通）、桥端 ' + BT + 'mem_*/mem2_*' + BT + ' 仍 ' + BT + 'wr=rd=wm' + BT + ' 且错误计数 0。\n\n')
assert anchor in s, 'failure-table anchor not found'
s = s.replace(anchor, storm + anchor, 1)

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)
print('J4 doc updated: step5 -> quality tier; storm subsection added')
