---
alias: 复现_prj10_指南
type: 操作文档
摘要: prj10 复现指南——在 prj9 光回环两侧各插一级 DDR4（内存进环路）后的复现。含位流 SHA256 闸门、烧录体检、数据面回归（ping + 四档 DDR）、导师原话验证（正常版/报错版）、随机读判据引擎、死锁专项回归、命令通道裸探测、W6 可观测性三件套、ILA 四域快照。每条命令可直接复制。
created: 2026-10-09
updated: 2026-10-09
---

# prj10 复现指南

> **prj10 是什么**：在 prj9 的「以太网 ↔ Aurora 光回环」通路的**光口两侧各插一级 DDR4**，数据面从流式直通变为**按地址存储转发**。
> **复现目标**：① 数据真实穿过两级内存（不是 FIFO 直通）；② **按地址随机读** —— 读出顺序 ≠ 写入顺序，且每帧内容与其槽位严格对应；③ 写进去的都能取出来。

---

## 一、复现工具一览

| 工具 | 作用 |
|---|---|
| `mentor_verify.py` | **导师原话验证报告（终端截图版）**：四环节逐条取证 + 逐帧对应表 + 判据核对 |
| `j3_random_read.py` | **J3/J3′ 判据引擎**：随机置换读取计划、逐条 READ_SLOT、集合级比对（含负向 A/B） |
| `udp_verify_ddr.py` | **数据面四档闭环**：链路档 / 基础档 / 槽深档 / 稳定档 |
| `deadlock_regress.py` | **写槽游标死锁专项回归**（灌满 256 槽不读，验证桥不卡死） |
| `rate_probe.py` | **速率上限探测**：命令通道读板内计数，分离「PC 发出 / 板内到达 / 入口丢 / 出口丢」 |
| `sim/pump_stress_tb.v` | **帧泵背靠背压力 TB**：200 帧 x 86B 帧间 10 拍，**逐字节校验**（原版丢 50% / L1 零丢）|
| `cmd_probe.py` | **命令通道裸探测**：逐包打印，区分「自有广播回环」与「板子应答」 |
| `w6_inventory.py` | 可观测性清单（从构建脚本 + RTL **自动生成**，含未挂 ILA 的缺口） |
| `w6_healthcheck.py` | **四域快照自检**：逐行校验硬件恒等式 + 静态判据 |
| `w6_archive.py` | 归档索引（41 条交付物带 SHA256 指纹） |
| `program_loop.tcl` | **一键烧录 + 体检** |
| `dbg_snap.tcl` | **四域 ILA 立刻快照** |
| `build_debug.tcl` | 位流构建（含 4 个 ILA 按域分挂） |

---

## 二、执行命令（可直接复制）

### 第 0 步：位流闸门（**不通过就不要烧**）

~~~powershell
(Get-FileHash D:\FPGA\prj\project_10\prj_loop\out\aurora_mem_bridge.bit -Algorithm SHA256).Hash
# 期望: DBE3573437DF24C6DDA4447FC4803E2EA9022879FA814D31A27A142EF50B017F
#   (该版 = W5/W6 全部判据 + L1 乒乓泵速率修复; WNS +0.019)
#   速率修复前已归档版: 6ACFF515…(W5验证) / ADC29764…(L2) —— 见 out/archive/
~~~

### 第 1 步：烧录 + 体检

~~~powershell
cd D:\FPGA\prj\project_10\prj_loop
vivado -mode batch -source scripts\program_loop.tcl -notrace
~~~

判据：`PROGRAM_OK` · `End of startup status: HIGH` · **4 个 ILA + 1 个 MIG** · 四个时钟域都在跑

### 第 2 步：数据面回归

~~~powershell
ping 192.168.1.10 -n 20        # 期望 20/20, 0% loss
cd D:\FPGA\prj\project_10\prj_loop
$env:PYTHONUTF8 = 1
python scripts\udp_verify_ddr.py          # 期望 DDR_VERIFY: PASS（全档）
python scripts\udp_verify_ddr.py --quick  # 只跑 [1][2][3]
~~~

### 第 3 步：导师原话验证（**终端截图用这个**）

~~~powershell
python scripts\mentor_verify.py                       # 【完全正常传输版】默认
python scripts\mentor_verify.py --mode fault          # 【异常报错版】负向对照
python scripts\mentor_verify.py --nslots 64 --pace-us 200   # 高速档
python scripts\mentor_verify.py --mock                # 无板自检（回环端口）
~~~

| 参数 | 说明 |
|---|---|
| `--mode normal` | 只跑主轮 + 速率，结论行 `★ 完全正常传输：PASS` |
| `--mode fault` | 跑负向 A/B，逐条列出「构造 / 实测 / 报错内容 / 判定」 |
| `--nslots` | 帧数（默认 16） |
| `--pace-us` | 帧间隔 µs（默认 1500；越小越快） |
| `--pc-ip` | PC 源网卡 IP（**默认 192.168.1.102**；多网卡机器必带） |
| `--mock` | 无板卡时的自检（回环端口） |

### 第 4 步：随机读判据引擎（想看原始数据/自定义时）

~~~powershell
# 主轮（严格模式：不产生写阶段回显）
python scripts\j3_random_read.py --nslots 16 --pace-us 1500 --no-write-echo `
       --src-ip 192.168.1.102 --full-json --json-out out\j3.json

# 含两个负向轮（证明判据非恒真）
python scripts\j3_random_read.py --nslots 16 --pace-us 1500 --no-write-echo `
       --neg-a --neg-b --src-ip 192.168.1.102
~~~

### 第 5 步：死锁专项回归（**会灌满槽，跑完建议重烧复位**）

~~~powershell
python scripts\deadlock_regress.py --n 300
~~~

期望：`DEADLOCK_REGRESS: PASS` —— 帧量守恒（接受 256 + 拒收 44 = 300）+ 灌满绕环后**桥仍存活**（读回 16/16）。

### 第 6 步（可选）：命令通道裸探测

~~~powershell
python scripts\cmd_probe.py 03 0 --timeout 2.0    # op=0x03 GET_WATERMARK
# 期望: [.. ] 192.168.1.10 len=12 ★板子应答 P10R op=0x03 status=0x00
~~~

### 第 7 步：可观测性三件套（W6 交付）

~~~powershell
python scripts\w6_inventory.py                  # 可观测性清单（自动，含缺口）
python scripts\w6_healthcheck.py --selftest     # 自检工具自身校验
python scripts\w6_healthcheck.py out\dbg_now1   # 四域快照自检
python scripts\w6_archive.py                    # 归档索引（带指纹）
~~~

### 第 8 步（可选）：四域 ILA 快照

~~~powershell
vivado -mode batch -source scripts\dbg_snap.tcl -tclargs w6check
python scripts\w6_healthcheck.py out\dbg_w6check
~~~

### 第 9 步：速率验证（L1 乒乓泵修复后）

> **方法要点（坑账本 #31）**：测**板卡上限**时必须让 PC 的报价**显著高于**被测上限。用 `--pace-us 20` 时
> PC 最多只能报 50k fps，会把 128B 档的板卡真实上限（≥117k）**遮住**，线性拟合于是把「PC 的节拍」
> 误当成「板卡的固定开销」。**本步骤固定用 `--pace-us 5`。**

~~~powershell
cd D:\FPGA\prj\project_10\prj_loop
$env:PYTHONUTF8 = 1

# 三档帧长，看板卡上限与入口丢帧
foreach ($L in @(128, 512, 1466)) {
    python scripts\rate_probe.py --n 3000 --pace-us 5 --len $L
}
~~~

判据：**三档 `入口丢` 都应为 `0 帧 (0.00%)`**，且 `u_wr_frame` 增量 = 3000。

预期输出（**修复后**）：

~~~
[len=128]  ① PC 发出 : 3000 帧 / 0.024s = 125235 帧/秒
           ② 板内到达内存桥: u_wr_frame 增量 3000
           **入口丢 (泵A 闸门): 0 帧 (0.00%)**
[len=512]  ① PC 发出 : 3000 帧 / 0.025s = 120362 帧/秒
           ② 板内到达内存桥: u_wr_frame 增量 3000
           **入口丢 (泵A 闸门): 0 帧 (0.00%)**
[len=1466] ① PC 发出 : 3000 帧 / 0.036s = 82670 帧/秒
           ② 板内到达内存桥: u_wr_frame 增量 3000
           **入口丢 (泵A 闸门): 0 帧 (0.00%)**
~~~

**修复前对照**（同一条命令，L1 之前的位流）：

| 帧长 | 修复前到达 | 修复前入口丢 | **修复后到达** | **修复后入口丢** |
|---|---|---|---|---|
| 128 B | 2,942/3,000 | 1.93% | 3,000/3,000 | **0.00%** |
| 512 B | 1,680/3,000 | 44.00% | 3,000/3,000 | **0.00%** |
| 1466 B | 1,500/3,000 | **50.00%** | 3,000/3,000 | **0.00%** |

> 1466B 帧 **82.67k fps** 已是**千兆线速口径**（理论上限 81.27k fps），折算 **≈969 Mbps**（修复前 489 Mbps）。

### 第 10 步（可选）：PRJ9 同款吞吐档

用 prj9 的 `json_storm.py` 跑与 J4 相同口径的冲击档：

~~~powershell
# ★前置：确保板子处于 SEQ 模式（RND 下不自动读，回显全丢，会误判为故障）
python D:\FPGA\prj\project_10\prj_loop\scripts\cmd_probe.py 01 0 --timeout 2.0
# 期望: PROBE: RESPONSE_OK

cd D:\FPGA\prj\project_9
python scripts\json_storm.py testdata\session_full.jsonl --chunk 1466 --pace-us 13 --out out\rate_check.jsonl
~~~

预期：`收到片数 7021/7022（99.99%）` · `损坏 0` · `逆序对 0` · 发送阶段速率 ≈85 MB/s（684 Mbps）
（**修复前同口径只有 51.45%、49.89 MB/s**）

### 第 11 步（可选）：仿真层复现速率修复（**无需上板**，约 1 分钟）

同一条 TB 跑两版 RTL 做**正负对照**：

~~~powershell
cd D:\FPGA\prj\project_10\sim
$XV = 'D:\Xilinx\Vivado\2023.1\bin'

# 负向对照：prj9 原版泵（握手门控）→ 背靠背必丢一半
& "$XV\xvlog.bat" -sv pump_stress_tb.v ..\prj\rtl\frame_fifo_pump.v
& "$XV\xelab.bat" -debug typical pump_stress_tb -s ps_orig
& "$XV\xsim.bat" ps_orig -R

# 正向：L1 乒乓泵（prj10 派生）→ 零丢帧 + 逐字节一致
& "$XV\xvlog.bat" -sv pump_stress_tb.v ..\prj_loop\rtl_patch\frame_fifo_pump.v
& "$XV\xelab.bat" -debug typical pump_stress_tb -s ps_l1
& "$XV\xsim.bat" ps_l1 -R
~~~

预期输出：

~~~
原版: RESULT: sent=200 wr_frame_cnt=100 wr_drop_cnt=100 rd_frame_cnt=100 rd_bytes=8600 byte_errs=0
      PUMP_STRESS: DROP (100/200 帧被丢弃 —— 握手门控的固有行为)

L1  : RESULT: sent=200 wr_frame_cnt=200 wr_drop_cnt=0 rd_frame_cnt=200 rd_bytes=17200 byte_errs=0
      PUMP_STRESS: PASS (0 丢帧, 200 帧 x 86 B 全部逐字节一致)
~~~

> **两条判读要点（坑账本 #32）**：
> ① `rd_bytes` 必须是 **17200 = 200×86**。若得到 `17000`（=200×85），说明泵有**每帧丢首字节**的
>    off-by-one；**只数帧数的 TB 抓不住它**，所以判据里必须有 `byte_errs`。
> ② **xvlog 报 ERROR 后 xelab 仍会用旧快照跑出结果** —— 必须确认 xvlog **零 ERROR**，否则跑的是旧产物。
---

## 三、判据与预期输出

### 3.1 导师原话四环节（`mentor_verify.py`）

| 环节 | 期望输出 |
|---|---|
| ① 先写到内存 | `板内写计数 u_wr_frame : X -> Y（增量 16，期望 16）OK` |
| ② 按指定地址读出 | `逆序对数 = 52   > 0` + 逐帧对应表 `16/16 OK` |
| ③ 经光回环再存 | 链路说明（桥①读 → Aurora → 光纤往返 → 桥② → 第二级 DDR4） |
| ④ 从内存发回 PC | `收帧数 16/16` · `缺 0` · `多 0` · `字节差异 0` |

判据表（脚本独立复核，不采信引擎 PASS 字样）：

~~~
J3 (a) 读出顺序 != 写入顺序       逆序对 52                         OK
J3 (b) 每帧内容与槽严格对应       16/16 逐步一致                    OK
J3' 集合级可取出性                收 16/期望 16 缺 0 多 0 字节差 0  OK
负向A 故意漏读 1 槽 -> 判据必须报出来   报缺 1 帧                     OK
负向B 重复读同槽 -> 必须观测到「空」    命令 17 条 / 实取 16 帧 / 额外 0 OK
~~~

### 3.2 W6 自检（`w6_healthcheck.py`）

| 判决 | 含义 |
|---|---|
| `W6_HEALTHCHECK: PASS` | 逐行硬件恒等式 + 静态判据全部成立 |
| `W6_HEALTHCHECK: FAIL` | 见逐项 `XX`；最常抓到的死锁特征 = `跨域提交滞后 mem_u_wr - wm` 超警戒线 32 |

**已用正负对照验证**：5 个健康快照 PASS、1 个死锁快照 FAIL（滞后 = 56）。

---

## 四、RND 模式的三个必知副作用

| # | 副作用 | 说明 |
|---|---|---|
| 1 | **板子无法主动发帧给 PC** | RND 下桥① 不自动读，ARP 应答也出不来 ⇒ PC 邻居表老化 ⇒ 单播丢帧。**引擎已自愈**：每轮先 `SET_MODE(SEQ)` 预热 ARP 再切 RND |
| 2 | **ping 会失败** | ICMP 回包被写进内存取不出来 —— 这是**设计使然**，不是故障。ping 只在 `SET_MODE(SEQ)` 后有效 |
| 3 | **写满槽会整帧拒收** | 属设计行为（不覆盖未读槽），表现为 `u_buf_drop` 增加；帧量守恒（接受 + 拒收 = 发出） |

---

## 五、失败时的第一步

| 现象 | 先查 |
|---|---|
| 命令无应答 | 位流 SHA256 是否对；`cmd_probe.py` 裸探测看有没有 `P10R` |
| 单播丢 14/16，命令正常 | **正常的 RND 副作用**（见 §四.1）→ 用 `mentor_verify.py`（已内置自愈），或加静态邻居项 |
| 读回 0 帧但命令 16/16 | 疑似写槽游标停滞 → 抓四域快照跑 `w6_healthcheck.py` 看「跨域提交滞后」 |
| 位流烧了但 ILA 抓不到 | 位流与 `.ltx` 必须同批（本设计有 4 个调试核） |

---

*命令均取自脚本真实 `--help`、干跑与验收记录；位流指纹见 `out\W6_报告归档索引.md`。*