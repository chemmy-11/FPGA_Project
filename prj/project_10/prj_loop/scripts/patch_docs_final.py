# -*- coding: utf-8 -*-
import io, os
NL = chr(10)
V = r'C:\\Users\\15266\\Desktop\\毕设'

def patch(P, old, new, must=1):
    s = io.open(P, encoding='utf-8').read()
    n = s.count(old)
    assert n == must, 'anchor x%d in %s' % (n, os.path.basename(P))
    s = s.replace(old, new, 1)
    t = P + '.tmp'
    io.open(t, 'w', encoding='utf-8', newline=NL).write(s)
    assert os.path.getsize(t) > 2000
    os.replace(t, P)
    print('patched', os.path.basename(P))

RATE = ('**✅ 速率问题已修复并上板收敛（2026-10-09 22:57）**：根因 = prj9 帧泵的**握手门控**'
        '（帧在途时到达的帧整帧丢弃，背靠背压测丢 50%）。**L1 修法** = 乒乓双 bank 泵'
        '（派生副本 `rtl_patch/frame_fifo_pump.v`，**prj9 原件零改动**），帧尾立即翻 bank 接收下一帧。'
        '**实测**：1466B 帧 **41.7k → 82.67k fps 且零丢帧**（≈969 Mbps，线速）；'
        '**PRJ9 同款吞吐档 51.45% → 99.99%**；发送速率 399 → 684 Mbps。'
        '**功能回归全过**：DDR 四档逐字节 PASS、导师原话 J3/J3′ PASS（正常版+报错版）、死锁专项 PASS、稳定性 3/3。'
        '**时序 WNS +0.019**（比修复前更好）。位流 `DBE35734…017F`。'
        '实施中还抓到并修掉 3 个缺陷（首字节 off-by-one、RAM 推断失败变 FF、拆块引入的多驱动），'
        '新增坑账本 #31–#34。记录 [[调试记录/阶段三_prj10_速率瓶颈诊断与L2写路径流水化_2026-10-09]]。')

patch(V + r'\\agent.md', '**✅ W6 可观测性收口完成（2026-10-09）**', RATE + ' **W6 可观测性收口完成（2026-10-09）**')
patch(V + r'\\追踪_cross_短期待办_2026-08-03.md', '**✅ W6 可观测性收口完成（2026-10-09）**', RATE + ' **W6 可观测性收口完成（2026-10-09）**')
patch(V + r'\\操作文档\\阶段三_prj10_W5随机读上板验证单_2026-10-07.md',
      '> **位流（最终）**：',
      ('> **位流（最终 · 含速率修复）**：`out/aurora_mem_bridge.bit`（2026-10-09 22:56，9785092 B，'
       'SHA256 `DBE3573437DF24C6DDA4447FC4803E2EA9022879FA814D31A27A142EF50B017F`，**WNS +0.019**）。' + NL +
       '> 该版在原 W5/W6 判据之上叠加 **L1 乒乓泵速率修复**：1466B 帧 41.7k→82.67k fps 零丢帧（≈969 Mbps 线速），' + NL +
       '> PRJ9 同款吞吐档 51.45%→99.99%；DDR 四档 / 导师原话（正常+报错）/ 死锁专项 / 稳定性 3/3 全过。' + NL +
       '> 历史位流（速率修复前）：'))
