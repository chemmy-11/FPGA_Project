# -*- coding: utf-8 -*-
import io, os
P = r'C:\\Users\\15266\\Desktop\\毕设\\操作文档\\阶段三_prj10_W5随机读上板验证单_2026-10-07.md'
BT = chr(96); NL = chr(10)
s = io.open(P, encoding='utf-8').read()

# 1) 横幅标题替换
old_t = '> ## ⛔ 暂缓执行（2026-10-08 00:15 更新 · 第二轮）'
new_t = '> ## ✅ 恢复执行（2026-10-08 19:35 —— W5 位流已达时序门限）' + NL + '>' + NL + '> **WNS = +0.001 / WHS = +0.004 / 全时钟域 0 失败端点**（第 8 轮构建，' + BT + 'build_w5_mir2.log' + BT + '，' + BT + 'W5_BUILD_OK' + BT + '）。' + NL + '> 时序攻坚全程 −1.121 → −0.494 → −0.121 → **+0.001**，四仿真全绿（计数逐字一致）。'
assert s.count(old_t) == 1, 'banner title x%d' % s.count(old_t)
s = s.replace(old_t, new_t, 1)

# 2) 旧横幅正文整体删除（从'本单当前不可执行'到'再来烧录。'两段）
lines = s.split(NL)
i0 = next(i for i, L in enumerate(lines) if '本单当前不可执行' in L)
i1 = next(i for i, L in enumerate(lines) if '再来烧录' in L and i > i0)
new_body = [
  '> **根因已由对照实验链定案**（详见 [[调试记录/阶段三_prj10_W5时序收敛_第三轮根因验证与收敛_2026-10-08]]）：主因 = **读命令解码锥**（' + BT + 'u_rd_cmd' + BT + ' 的 FWFT 组合读出 → 范围比较 → 槽选择 → ' + BT + 'full_bit/len_tab' + BT + ' 256:1 查表，占缺口 4/5），次因 = cmd_channel 集成负载（约 0.08ns）。最终修法 = 预取拍做范围数学并寄存 + ' + BT + 'len_beats_tab' + BT + ' 预算表 + **keep 保护的 ' + BT + 'full_bit_q' + BT + ' 镜像**（无 keep 会被综合器合并回原树、收益归零——坑账本 #28）。',
  '> **位流**：' + BT + 'out/aurora_mem_bridge.bit' + BT + '（2026-10-08 19:31:22，9,856,668 B，SHA256 ' + BT + '18387F8C6A28F0FB72E491C3A50CF5CF3996A1A72A62C438B8B8A050325FDF9E' + BT + '），' + BT + 'probes.ltx' + BT + ' 同批产出（19:30:28）——**配对一致**。',
]
lines[i0:i1+1] = new_body
s = NL.join(lines)

# 3) 第 1 步闸门里的旧 SHA/时间戳更新
s = s.replace('预期：' + BT + '.bit' + BT + ' 时间戳为 **2026-10-07 晚（W5 版）**，SHA256 与本次构建记录一致（见 W5 执行记录）。不符 → 停下来发我。',
            '预期：' + BT + '.bit' + BT + ' 时间戳为 **2026-10-08 19:31**（W5 达标版），SHA256 = ' + BT + '18387F8C6A28F0FB72E491C3A50CF5CF3996A1A72A62C438B8B8A050325FDF9E' + BT + '。不符 → 停下来发我，不要烧。', 1)

tmp = P + '.tmp'
io.open(tmp, 'w', encoding='utf-8', newline=NL).write(s)
assert os.path.getsize(tmp) > 8000
os.replace(tmp, P)
chk = io.open(P, encoding='utf-8').read()
assert '恢复执行' in chk and '18387F8C' in chk and '暂缓执行' not in chk
print('board sheet restored: %d bytes' % len(chk.encode('utf-8')))