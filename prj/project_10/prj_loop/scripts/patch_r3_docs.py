# -*- coding: utf-8 -*-
import io, os
NL = chr(10)

def patch(P, old, new, must=1):
    s = io.open(P, encoding='utf-8').read()
    c = s.count(old)
    assert c == must, 'anchor x%d in %s' % (c, P)
    s = s.replace(old, new, 1)
    tmp = P + '.tmp'
    io.open(tmp, 'w', encoding='utf-8', newline=NL).write(s)
    assert os.path.getsize(tmp) > 5000
    os.replace(tmp, P)
    print('patched', os.path.basename(P))

T = r'C:\\Users\\15266\\Desktop\\毕设\\追踪_cross_短期待办_2026-08-03.md'
patch(T, '**⛔ 暂停于时序收敛（2026-10-08 00:15 更新 · 第二轮）**',
      '**✅ 时序已收敛（2026-10-08 19:35 第三轮），待 J5 上板**：根因经对照实验链定案——主因 = 读命令解码锥（结构性移除实验 −0.494→−0.074，占缺口 4/5）+ 次因 cmd_channel 负载（≈0.08ns）；两次「cfg 常量对照」无效（LUTRAM 宏不透明，坑 #28）。最终修法（预取拍做范围数学 + len_beats_tab 预算表 + keep 保护的 full_bit_q 镜像）8 轮构建 **−1.121 → +0.001**，四仿真全绿、计数逐字一致；**位流达标**（SHA256 18387F8C…FDF9E，19:31:22，与 probes.ltx 配对）。**下一步 = J5 上板**（[[操作文档/阶段三_prj10_W5随机读上板验证单_2026-10-07]] 已恢复就绪）。第三轮定案 [[调试记录/阶段三_prj10_W5时序收敛_第三轮根因验证与收敛_2026-10-08]]；第二轮（已修订）')

A = r'C:\\Users\\15266\\Desktop\\毕设\\agent.md'
patch(A, '**⛔ 暂停于时序收敛（第二轮，2026-10-08 00:15）**',
      '**✅ 时序已收敛（2026-10-08 19:35 第三轮）**：对照实验链定案根因（锥 0.42ns 主因 + cmd_channel 0.08ns 次因；常量对照无效 = LUTRAM 宏不透明，坑 #28）；最终修法 8 轮 −1.121 → **+0.001**，四仿真全绿；**位流达标 SHA256 18387F8C…FDF9E（与 probes.ltx 配对），待 J5 上板**（验证单已恢复就绪）。定案 [[调试记录/阶段三_prj10_W5时序收敛_第三轮根因验证与收敛_2026-10-08]]；第二轮（已修订）')