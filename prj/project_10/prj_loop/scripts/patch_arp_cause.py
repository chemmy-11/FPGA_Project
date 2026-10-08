# -*- coding: utf-8 -*-
import io, os
NL = chr(10)
V = r'C:\\Users\\15266\\Desktop\\毕设'

def patch(P, old, new, must=1):
    s = io.open(P, encoding='utf-8').read()
    n = s.count(old)
    assert n == must, 'anchor x%d in %s' % (n, os.path.basename(P))
    s = s.replace(old, new, 1)
    tmp = P + '.tmp'
    io.open(tmp, 'w', encoding='utf-8', newline=NL).write(s)
    assert os.path.getsize(tmp) > 2000
    os.replace(tmp, P)
    print('patched', os.path.basename(P))

NOTE = (
  '> ⚠️ **RND 模式的固有副作用（必读，已用工具自愈）**：RND 下桥① 不自动读 ⇒ '
  '**板子无法主动发任何帧给 PC**（ARP 应答也要经「内存→泵B」）⇒ PC 邻居表老化成 '
  '`Unreachable`（`Get-NetNeighbor 192.168.1.10` 可见）⇒ **单播数据帧被直接丢弃**，'
  '而**广播命令不需要 ARP**、通道一直正常 —— 表现为「命令通、数据丢 14/16」，'
  '极易误判为板卡故障或 WLAN 抢路由（**两者都不是**）。' + NL +
  '> **工具已自愈**：`j3_random_read.py` 每轮开测前先 `SET_MODE(SEQ)`（板子即可应答 ARP）'
  '→ UDP 单播探测刷新邻居表 → 再切 `RND` 正式开测；收尾恢复 `SEQ`。' + NL +
  '> 实测（WLAN 全程连接）：连续 4 轮 **全部 PASS**（增量 16/16）。' + NL +
  '> 若想彻底免掉 ARP（可选，需管理员）：' + NL +
  '> `New-NetNeighbor -InterfaceAlias \'以太网\' -IPAddress 192.168.1.10 -LinkLayerAddress 00-11-22-33-44-55 -State Permanent`')

# 1) 上板验证单: 用正确归因替换先前那条“WLAN 抢路由”的注意事项
S = V + r'\\操作文档\\阶段三_prj10_W5随机读上板验证单_2026-10-07.md'
old_s = (
  '> ⚠️ **多网卡机器注意**：WLAN 在线时 Windows 可能把到板卡的流量路由到 WLAN，表现为「命令无应答 / 单播数据帧丢失」。用 `python scripts\\j3_random_read.py --src-ip 192.168.1.102 …` 显式指定源网卡，或临时断开 WLAN。**这不是板卡问题**。')
patch(S, old_s, NOTE)

# 2) 汇报: 同样替换
R = V + r'\\汇报\\导师原话验证报告_prj10内存进环路_2026-10-08.md'
old_r = (
  '> ⚠️ **多网卡机器注意**：若同时接了 WLAN，Windows 可能把到板卡的流量路由到 WLAN，表现为「命令无应答 / 单播数据帧丢失」。届时用 `--src-ip 192.168.1.102` 显式指定源网卡，或临时断开 WLAN。**这不是板卡问题**（本轮实测复现过，见证据日志）。')
patch(R, old_r, NOTE)

# 3) 死锁记录: 补上 ARP 现象的准确归因(原写的是“解析窗口丢帧”，不完整)
D = V + r'\\调试记录\\阶段三_prj10_W5写槽游标死锁_2026-10-08.md'
old_d = '机制：数据帧是**单播**到板卡 IP；ARP 条目老化/缺失时，Windows 在解析窗口内发出的帧被直接丢弃，解析完成约需 21ms ⇒ 只有最后 2 帧赶上。这完全解释了「每次重跑的第一轮必失败、之后通过」。'
new_d = ('机制（准确版，2026-10-08 深夜修正）：**RND 模式下板子根本无法应答 ARP** —— RND 下桥① 不自动读，板子要发的任何帧（含 ARP 应答）都得走「栈 → 泵A → 内存 → …」这条路，而 RND 不自动读 ⇒ 应答帧出不来 ⇒ PC 邻居表老化成 `Unreachable`（`Get-NetNeighbor 192.168.1.10` 实测 MAC 全 0）⇒ 单播数据帧被直接丢弃；广播命令不需要 ARP，故通道一直正常。' + NL +
           '先前的「Windows 在 ARP 解析窗口丢帧」只是表象。**修法**：引擎每轮开测前先切 `SEQ`（板子能应答 ARP）→ UDP 探测刷新邻居表 → 再切 `RND`；收尾恢复 `SEQ`。实测 WLAN 全程连接下连续 4 轮全 PASS。')
patch(D, old_d, new_d)