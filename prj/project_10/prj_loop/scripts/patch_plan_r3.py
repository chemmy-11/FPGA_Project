# -*- coding: utf-8 -*-
import io, os
NL = chr(10)
P = r'C:\\Users\\15266\\Desktop\\毕设\\操作文档\\阶段三_prj10_内存进环路开工草案_2026-09-29.md'
s = io.open(P, encoding='utf-8').read()
old = '**⛔ 2026-10-07 晚 ~ 10-08 凌晨暂停于时序收敛（第二轮已推进）**'
new = '**✅ 2026-10-08 19:35 时序已收敛（第三轮）**：根因经对照实验链定案——主因 = 读命令解码锥（结构性移除 −0.494→−0.074）+ 次因 cmd_channel 负载（0.08ns）；常量对照无效（LUTRAM 宏不透明，坑 #28）。最终修法（预取拍范围数学 + len_beats_tab + keep 镜像 full_bit_q）8 轮 **−1.121 → +0.001**，四仿真全绿；位流达标（SHA256 18387F8C…FDF9E）待 J5 上板，见 [[调试记录/阶段三_prj10_W5时序收敛_第三轮根因验证与收敛_2026-10-08]]。**第二轮过程（已修订）**'
assert s.count(old) == 1, 'x%d' % s.count(old)
s = s.replace(old, new, 1)
tmp = P + '.tmp'
io.open(tmp, 'w', encoding='utf-8', newline=NL).write(s)
os.replace(tmp, P)
print('plan patched')