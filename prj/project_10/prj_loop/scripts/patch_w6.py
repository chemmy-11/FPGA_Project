# -*- coding: utf-8 -*-
import io, os
NL = chr(10)
V = r'C:\\Users\\15266\\Desktop\\毕设'

def patch(P, old, new):
    s = io.open(P, encoding='utf-8').read()
    assert s.count(old) == 1, 'anchor x%d in %s' % (s.count(old), os.path.basename(P))
    s = s.replace(old, new, 1)
    t = P + '.tmp'
    io.open(t, 'w', encoding='utf-8', newline=NL).write(s)
    assert os.path.getsize(t) > 3000
    os.replace(t, P)
    print('patched', os.path.basename(P))

W6 = ('**✅ W6 可观测性收口完成（2026-10-09）**：判据「可观测可复现」三项全达成——'
      '①**判决计数器总表**（从 build_debug.tcl + RTL **自动生成**，49 信号 / 795 bit）；'
      '②4 个 ILA **按域分挂**核对（user_clk 404b / eth_rxc 111b / user_clk_b 101b / ui_clk 179b，无跨域采样）；'
      '③**归档索引** 41 条带 SHA256 指纹、0 缺失。新建三脚本 `w6_inventory.py` / `w6_healthcheck.py` / `w6_archive.py`。'
      '**自检经正负对照验证**：5 个健康快照 PASS、1 个死锁快照 FAIL（跨域提交滞后 = 56，独立复现人工定位的 334 vs 278）。'
      '**诚实缺口**：4 个桥内部计数器因挂 ILA3 会把 300MHz 域打崩（WNS −0.041→−1.142）而**未挂、仅 xsim 可见**，已在清单与验收记录明确标注并给替代路径。'
      '**⇒ 路线 A（W0–W6）收口，B 的启动条件满足。** 记录 [[调试记录/阶段三_prj10_W6可观测性收口_2026-10-09]]。')

patch(V + r'\\agent.md', '**✅ W5 上板验证通过（2026-10-08 晚，J5）**', W6 + ' **W5 上板验证通过（2026-10-08 晚，J5）**')
patch(V + r'\\追踪_cross_短期待办_2026-08-03.md', '**✅ W5 已上板验证通过（2026-10-08 晚）**', W6 + ' **W5 已上板验证通过（2026-10-08 晚）**')