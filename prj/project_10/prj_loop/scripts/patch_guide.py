# -*- coding: utf-8 -*-
import io, os
NL = chr(10)
G = r'C:\\Users\\15266\\Desktop\\毕设\\复现\\prj10_复现指南.md'
s = io.open(G, encoding='utf-8').read()
n0 = len(s)

# ---- 1) 工具表: 补 rate_probe.py ----
a1 = '| `deadlock_regress.py` | **写槽游标死锁专项回归**（灌满 256 槽不读，验证桥不卡死） |'
assert s.count(a1) == 1
s = s.replace(a1, a1 + NL + '| `rate_probe.py` | **速率上限探测**：命令通道读板内计数，分离「PC 发出 / 板内到达 / 入口丢 / 出口丢」 |'
              + NL + '| `sim/pump_stress_tb.v` | **帧泵背靠背压力 TB**：200 帧 x 86B 帧间 10 拍，**逐字节校验**（原版丢 50% / L1 零丢）|', 1)

# ---- 2) 位流闸门: 换成含速率修复的当前版 ----
a2 = '# 期望: 6ACFF5150AE6794E8BF07C52375ADDA53A6B937192D06E8EDD2A5C6C5A2EA62B'
assert s.count(a2) == 1
s = s.replace(a2, '# 期望: DBE3573437DF24C6DDA4447FC4803E2EA9022879FA814D31A27A142EF50B017F' + NL
              + '#   (该版 = W5/W6 全部判据 + L1 乒乓泵速率修复; WNS +0.019)' + NL
              + '#   速率修复前已归档版: 6ACFF515…(W5验证) / ADC29764…(L2) —— 见 out/archive/', 1)

# ---- 3) 第 9~11 步: 插在「## 三、判据与预期输出」之前 ----
a3 = NL + '---' + NL + NL + '## 三、判据与预期输出'
assert s.count(a3) == 1
steps = [
  '',
  '### 第 9 步：速率验证（L1 乒乓泵修复后）',
  '',
  '> **方法要点（坑账本 #31）**：测**板卡上限**时必须让 PC 的报价**显著高于**被测上限。用 `--pace-us 20` 时',
  '> PC 最多只能报 50k fps，会把 128B 档的板卡真实上限（≥117k）**遮住**，线性拟合于是把「PC 的节拍」',
  '> 误当成「板卡的固定开销」。**本步骤固定用 `--pace-us 5`。**',
  '',
  '~~~powershell',
  'cd D:\\FPGA\\prj\\project_10\\prj_loop',
  '$env:PYTHONUTF8 = 1',
  '',
  '# 三档帧长，看板卡上限与入口丢帧',
  'foreach ($L in @(128, 512, 1466)) {',
  '    python scripts\\rate_probe.py --n 3000 --pace-us 5 --len $L',
  '}',
  '~~~',
  '',
  '判据：**三档 `入口丢` 都应为 `0 帧 (0.00%)`**，且 `u_wr_frame` 增量 = 3000。',
  '',
  '预期输出（**修复后**）：',
  '',
  '~~~',
  '[len=128]  ① PC 发出 : 3000 帧 / 0.024s = 125235 帧/秒',
  '           ② 板内到达内存桥: u_wr_frame 增量 3000',
  '           **入口丢 (泵A 闸门): 0 帧 (0.00%)**',
  '[len=512]  ① PC 发出 : 3000 帧 / 0.025s = 120362 帧/秒',
  '           ② 板内到达内存桥: u_wr_frame 增量 3000',
  '           **入口丢 (泵A 闸门): 0 帧 (0.00%)**',
  '[len=1466] ① PC 发出 : 3000 帧 / 0.036s = 82670 帧/秒',
  '           ② 板内到达内存桥: u_wr_frame 增量 3000',
  '           **入口丢 (泵A 闸门): 0 帧 (0.00%)**',
  '~~~',
  '',
  '**修复前对照**（同一条命令，L1 之前的位流）：',
  '',
  '| 帧长 | 修复前到达 | 修复前入口丢 | **修复后到达** | **修复后入口丢** |',
  '|---|---|---|---|---|',
  '| 128 B | 2,942/3,000 | 1.93% | 3,000/3,000 | **0.00%** |',
  '| 512 B | 1,680/3,000 | 44.00% | 3,000/3,000 | **0.00%** |',
  '| 1466 B | 1,500/3,000 | **50.00%** | 3,000/3,000 | **0.00%** |',
  '',
  '> 1466B 帧 **82.67k fps** 已是**千兆线速口径**（理论上限 81.27k fps），折算 **≈969 Mbps**（修复前 489 Mbps）。',
  '',
  '### 第 10 步（可选）：PRJ9 同款吞吐档',
  '',
  '用 prj9 的 `json_storm.py` 跑与 J4 相同口径的冲击档：',
  '',
  '~~~powershell',
  '# ★前置：确保板子处于 SEQ 模式（RND 下不自动读，回显全丢，会误判为故障）',
  'python D:\\FPGA\\prj\\project_10\\prj_loop\\scripts\\cmd_probe.py 01 0 --timeout 2.0',
  '# 期望: PROBE: RESPONSE_OK',
  '',
  'cd D:\\FPGA\\prj\\project_9',
  'python scripts\\json_storm.py testdata\\session_full.jsonl --chunk 1466 --pace-us 13 --out out\\rate_check.jsonl',
  '~~~',
  '',
  '预期：`收到片数 7021/7022（99.99%）` · `损坏 0` · `逆序对 0` · 发送阶段速率 ≈85 MB/s（684 Mbps）',
  '（**修复前同口径只有 51.45%、49.89 MB/s**）',
  '',
  '### 第 11 步（可选）：仿真层复现速率修复（**无需上板**，约 1 分钟）',
  '',
  '同一条 TB 跑两版 RTL 做**正负对照**：',
  '',
  '~~~powershell',
  'cd D:\\FPGA\\prj\\project_10\\sim',
  "$XV = 'D:\\Xilinx\\Vivado\\2023.1\\bin'",
  '',
  '# 负向对照：prj9 原版泵（握手门控）→ 背靠背必丢一半',
  '& "$XV\\xvlog.bat" -sv pump_stress_tb.v ..\\prj\\rtl\\frame_fifo_pump.v',
  '& "$XV\\xelab.bat" -debug typical pump_stress_tb -s ps_orig',
  '& "$XV\\xsim.bat" ps_orig -R',
  '',
  '# 正向：L1 乒乓泵（prj10 派生）→ 零丢帧 + 逐字节一致',
  '& "$XV\\xvlog.bat" -sv pump_stress_tb.v ..\\prj_loop\\rtl_patch\\frame_fifo_pump.v',
  '& "$XV\\xelab.bat" -debug typical pump_stress_tb -s ps_l1',
  '& "$XV\\xsim.bat" ps_l1 -R',
  '~~~',
  '',
  '预期输出：',
  '',
  '~~~',
  '原版: RESULT: sent=200 wr_frame_cnt=100 wr_drop_cnt=100 rd_frame_cnt=100 rd_bytes=8600 byte_errs=0',
  '      PUMP_STRESS: DROP (100/200 帧被丢弃 —— 握手门控的固有行为)',
  '',
  'L1  : RESULT: sent=200 wr_frame_cnt=200 wr_drop_cnt=0 rd_frame_cnt=200 rd_bytes=17200 byte_errs=0',
  '      PUMP_STRESS: PASS (0 丢帧, 200 帧 x 86 B 全部逐字节一致)',
  '~~~',
  '',
  '> **两条判读要点（坑账本 #32）**：',
  '> ① `rd_bytes` 必须是 **17200 = 200×86**。若得到 `17000`（=200×85），说明泵有**每帧丢首字节**的',
  '>    off-by-one；**只数帧数的 TB 抓不住它**，所以判据里必须有 `byte_errs`。',
  '> ② **xvlog 报 ERROR 后 xelab 仍会用旧快照跑出结果** —— 必须确认 xvlog **零 ERROR**，否则跑的是旧产物。',
]
s = s.replace(a3, NL.join(steps) + a3, 1)

io.open(G, 'w', encoding='utf-8', newline=NL).write(s)
assert os.path.getsize(G) > n0
print('guide patched:', n0, '->', len(s))
