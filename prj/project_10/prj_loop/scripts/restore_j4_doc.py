# -*- coding: utf-8 -*-
import io, os
MIRROR = r'D:\\FPGA\\docs\\操作文档\\阶段三_prj10_W4两级内存联调上板验证单_2026-10-07.md'
VAULT  = r'C:\\Users\\15266\\Desktop\\毕设\\操作文档\\阶段三_prj10_W4两级内存联调上板验证单_2026-10-07.md'
BT = chr(96); NL = chr(10); MU = chr(0xB5); BS = chr(92)
s = io.open(MIRROR, encoding='utf-8').read()
assert len(s.encode('utf-8')) > 10000, 'mirror too small: %d bytes' % len(s.encode('utf-8'))
n0 = s.count(NL) + 1
old_head = '## 第 5 步：10MB 全量 SHA（J4-4）' + NL + NL + '**操作**：' + NL + NL + '~~~powershell' + NL + '$env:PYTHONUTF8 = 1' + NL + 'cd D:' + BS + 'FPGA' + BS + 'prj' + BS + 'project_9' + NL + 'python scripts' + BS + 'json_storm.py testdata' + BS + 'session_full.jsonl --pace-us 13 --out out' + BS + 'w4j4_重组.jsonl' + NL + '~~~'
assert s.count(old_head) == 1, 'step5 head anchor count=%d' % s.count(old_head)
new_head = ('## 第 5 步：10MB 全量 SHA（J4-4）' + NL + NL + '> ⚠️ **2026-10-07 实测订正（重要）**：本步用**质量档（默认 1ms 间隔）**——' + BT + '--pace-us 13' + BT + ' 属 **E2/E3 类吞吐档**，实测会打满入口（泵A 单帧在途忙丢约 51%，见下方“吞吐档（可选）”）。首版验证单误把 pace13 写成完整性档，已订正。' + NL + NL + '**操作（完整性判据 · 质量档）**：' + NL + NL + '~~~powershell' + NL + '$env:PYTHONUTF8 = 1' + NL + 'cd D:' + BS + 'FPGA' + BS + 'prj' + BS + 'project_9' + NL + 'python scripts' + BS + 'json_storm.py testdata' + BS + 'session_full.jsonl --out out' + BS + 'w4j4_quality.jsonl' + NL + '~~~')
s = s.replace(old_head, new_head, 1)
anchor = '## 失败处置判读表（按现象查，一行一个处置）'
assert s.count(anchor) == 1, 'failure anchor count=%d' % s.count(anchor)
storm = ('## 吞吐档（可选 · 非 J4 判据）：pace 13' + MU + 's 冲击观测' + NL + NL + '**操作**：' + NL + NL + '~~~powershell' + NL + '$env:PYTHONUTF8 = 1' + NL + 'cd D:' + BS + 'FPGA' + BS + 'prj' + BS + 'project_9' + NL + 'python scripts' + BS + 'json_storm.py testdata' + BS + 'session_full.jsonl --pace-us 13 --out out' + BS + 'w4j4_storm.jsonl' + NL + '~~~' + NL + NL + '**实测口径（2026-10-07，勿误读）**：收到约 **51%**（3612/7022）、**损坏 0 / 乱序 0 / 板子不冻结**；丢失全部发生在**泵A 之前**（入口 ' + BT + 'pfwd_drop' + BT + ' 3402 ≈ PC 丢失 3410 − 泵B 丢 8），**两座内存桥零丢零错**。这是 prj9 已知的“泵A 单帧在途”结构特性（D2 描述符环解决），**不是 J4 完整性判据**；完整性看第 5 步质量档（100% + SHA 一致）。' + NL + NL + '**判据（若跑）**：损坏 0、乱序 0、板子不冻结（ping 仍通）、桥端 ' + BT + 'mem_*/mem2_*' + BT + ' 仍 ' + BT + 'wr=rd=wm' + BT + ' 且错误计数 0。' + NL + NL)
s = s.replace(anchor, storm + anchor, 1)
lines = s.split(NL)
hit = [i for i, L in enumerate(lines) if '为什么敢用 pace' in L]
assert len(hit) == 1, 'freeze lines=%r' % hit
lines[hit[0]] = '> **冻结口径（已修，仍留判据）**：过载冻结已修复（2026-10-06，git 9f29d7c）；2026-10-07 本轮实测 pace 13' + MU + 's 冲击下**板子不冻结**（看门狗计数 0、ping 仍通），只表现为入口丢帧——与修复前板端错乱、PC 几乎全丢、需重烧形成对照。'
s = NL.join(lines)
tmp = VAULT + '.tmp'
io.open(tmp, 'w', encoding='utf-8', newline=NL).write(s)
assert os.path.getsize(tmp) > 10000, 'tmp too small'
os.replace(tmp, VAULT)
chk = io.open(VAULT, encoding='utf-8').read()
assert '--pacE' not in chk
assert chk.count('质量档') >= 2 and '7F6AB35F3A89E31C' in chk
print('RESTORED+CORRECTED: %d bytes, %d lines (mirror was %d lines)' % (len(chk.encode('utf-8')), chk.count(NL)+1, n0))