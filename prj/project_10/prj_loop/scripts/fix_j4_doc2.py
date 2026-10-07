# -*- coding: utf-8 -*-
import io
P = r'C:\\Users\\15266\\Desktop\\毕设\\操作文档\\阶段三_prj10_W4两级内存联调上板验证单_2026-10-07.md'
lines = io.open(P, encoding='utf-8').read().split(chr(10))
hit = [i for i, L in enumerate(lines) if '为什么敢用 pace' in L]
assert len(hit) == 1, 'anchor lines: %r' % hit
i = hit[0]
lines[i] = '> **冻结口径（已修，仍留判据）**：过载冻结已修复（2026-10-06，git 9f29d7c）；2026-10-07 本轮实测 pace 13' + chr(0xB5) + 's 冲击下**板子不冻结**（看门狗计数 0、ping 仍通），只表现为入口丢帧——与修复前板端错乱、PC 几乎全丢、需重烧形成对照。'
io.open(P, 'w', encoding='utf-8', newline=chr(10)).write(chr(10).join(lines))
print('freeze note line replaced at', i)