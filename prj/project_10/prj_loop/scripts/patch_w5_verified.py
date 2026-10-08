# -*- coding: utf-8 -*-
import io, os
NL = chr(10)
V = r'C:\\Users\\15266\\Desktop\\毕设'

def patch(P, old, new, must=1):
    s = io.open(P, encoding='utf-8').read()
    n = s.count(old)
    assert n == must, 'anchor x%d (want %d) in %s' % (n, must, os.path.basename(P))
    s = s.replace(old, new, 1)
    tmp = P + '.tmp'
    io.open(tmp, 'w', encoding='utf-8', newline=NL).write(s)
    assert os.path.getsize(tmp) > 3000
    os.replace(tmp, P)
    print('patched', os.path.basename(P))

# 1) 上板验证单: 更新最终位流 SHA + 环境注意
S = V + r'\\操作文档\\阶段三_prj10_W5随机读上板验证单_2026-10-07.md'
patch(S, '> **位流**：`out/aurora_mem_bridge.bit`（2026-10-08 19:31:22，9,856,668 B，SHA256 `18387F8C6A28F0FB72E491C3A50CF5CF3996A1A72A62C438B8B8A050325FDF9E`），`probes.ltx` 同批产出（19:30:28）——**配对一致**。',
      '> **位流（最终）**：`out/aurora_mem_bridge.bit`（2026-10-08 22:12，SHA256 `6ACFF5150AE6794E8BF07C52375ADDA53A6B937192D06E8EDD2A5C6C5A2EA62B`，WNS **+0.010**），`probes.ltx` 同批——**配对一致**。' + NL +
      '> 历史版本：19:31 版 `18387F8C…FDF9E`（runt 缺陷）、22:0x 版（写槽游标死锁）——**均已废弃，勿烧**。' + NL +
      '> ⚠️ **多网卡机器注意**：WLAN 在线时 Windows 可能把到板卡的流量路由到 WLAN，表现为「命令无应答 / 单播数据帧丢失」。用 `python scripts\\j3_random_read.py --src-ip 192.168.1.102 …` 显式指定源网卡，或临时断开 WLAN。**这不是板卡问题**。')

# 2) agent.md
A = V + r'\\agent.md'
patch(A, '**✅ 时序已收敛（2026-10-08 19:35 第三轮）**',
      '**✅ W5 上板验证通过（2026-10-08 晚，J5）**：导师原话四环节全部取到板卡证据，J3 逆序对 52 / 逐帧对应 16/16 / J3′ 收 16/16 缺 0 多 0 字节差 0 / 负向 A 报缺 1 帧 / 负向 B 观测到「空」，引擎判决 PASS；终端一键复现 `scripts/mentor_verify.py`。过程中发现并修复**两处真实缺陷**：①应答帧是以太网 runt（58B<64B，网卡静默丢弃）→ 按 RFC 894 加 6B 填充 + TB 补最小帧长护栏；②RND 模式写槽游标死锁（接受 334 vs 提交 278 发散 56，游标停在满槽上永久卡死）→ 新增独立槽游标 `wr_slot_ptr`（专项回归 PASS）。另排除三个假故障（PC 侧 ARP 老化 / 工具应答配对 / LUTRAM 宏常量传播）。终版位流 SHA256 `6ACFF515…A62B`（WNS +0.010）。报告 [[汇报/导师原话验证报告_prj10内存进环路_2026-10-08]]。**时序收敛（第三轮）**')

# 3) 待办
T = V + r'\\追踪_cross_短期待办_2026-08-03.md'
patch(T, '**✅ 时序已收敛（2026-10-08 19:35 第三轮），待 J5 上板**',
      '**✅ W5 已上板验证通过（2026-10-08 晚）**：导师原话四环节全部取到板卡证据（J3 逆序对 52 / 逐帧 16/16 / J3′ 0 缺 0 多 / 负向 A 报缺 1 帧 / 负向 B 观测到空），终端一键复现 `scripts/mentor_verify.py`；过程中发现并修复 runt 帧与写槽游标死锁两处真实缺陷，排除三个假故障。终版位流 SHA256 `6ACFF515…A62B`。报告 [[汇报/导师原话验证报告_prj10内存进环路_2026-10-08]]。**时序收敛（第三轮，已上板）**')