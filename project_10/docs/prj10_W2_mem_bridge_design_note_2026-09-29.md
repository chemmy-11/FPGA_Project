# prj10 W2 内存桥 RTL 设计说明（2026-09-29）

> 本文件是工程侧设计说明（脱敏快照对象）。面向人的执行记录见 vault
> `操作文档/阶段三_prj10_内存桥RTL与仿真实操记录_2026-09-29.md`。
> 面向导师的需求对齐见 vault `汇报/汇报_阶段三_prj10_内存进环路需求对齐_2026-09-29.md`。

## 0. 范围（为什么 W2 是可开工部分）

prj10 开工草案把工作包编为 **W0–W6**。其中只有 **W2（内存桥 RTL + xsim 仿真）**
不依赖导师 Q1–Q5 拍板，也不依赖物理层：

| 待拍板项 | 对 W2 的影响 |
|---|---|
| Q1 是否必须走 MicroBlaze + AXI DMA | 只影响 `axi4_master_bridge` 这一层；草案 §四已把它拆成独立层，换 B 时不动其余 |
| Q2 写侧分槽/读侧指定 | W2 两种模式都实现了（SEQ/RND 显式分模） |
| Q3 读地址谁定 | 命令通道在 W2 里做成"寄存器+命令 FIFO"，UDP 命令字或 AXI-Lite 都只是上游 |
| Q4 单板双笼 vs 双板 | 与桥无关 |
| Q5 只做功能验证 | 与桥无关 |

**红线遵守**：未创建任何 Vivado 工程（无 .xpr、无综合、无实现、无位流）；未改动
`project_4`/`project_9` 任何文件；未涉及上板/插纤（物理层归用户）。
仿真只用 `xvlog/xelab/xsim` 三个批处理命令。

## 1. 交付物

```
project_10/
├── rtl/
│   ├── async_fifo.v            # 格雷码异步 FIFO（CDC 基元，FWFT）
│   ├── axi4_master_bridge.v    # ui_clk 域：AXI4 512b 主机 + 槽表 + 读写 FSM
│   └── frame_mem_if.v          # 顶层：帧侧接口 + 5 个 CDC FIFO + 寄存器 + 桥实例
├── sim/
│   ├── axi4_ram_model.v        # 行为级 AXI4 从机 + RAM + 监视器（MIG 替身）
│   ├── mem_bridge_tb.sv        # W2 验收 testbench（T1–T6）
│   ├── dbg_tb.sv               # 单帧 bring-up 追迹工具（排障用，非交付判据）
│   └── run_sim.ps1             # 一键复现：xvlog -> xelab -> xsim
└── docs/
    └── prj10_W2_mem_bridge_design_note_2026-09-29.md
```

## 2. 分层与接口预留（对应开工草案 §四）

| 层 | 文件 | 职责 | 演进到路线 B（AXI DMA）时 |
|---|---|---|---|
| 帧侧 | `frame_mem_if.v` | 帧边界、槽选择、水位、命令/寄存器、CDC | 保留 |
| 内存侧 | `axi4_master_bridge.v` | 突发、4KB 规则、槽表、AXI 握手、MIG 硬门控 | **只换这一层** |
| CDC | `async_fifo.v` | 用户域 ↔ ui_clk 跨域（5 个实例） | 保留（上板可换 FIFO IP） |

时钟域：`user_clk`（151.5 MHz，Aurora 用户钟）负责帧流；`ui_clk`（≈300 MHz，MIG）
负责 DDR 与槽表。**槽表（valid/len）只在 ui_clk 域，单时钟无跨域表风险**；
跨域只有三种合法形式：格雷指针异步 FIFO ×5、2FF 同步器 ×1（outstanding 格雷码计数镜像）。

CDC 清单：

| 方向 | 载体 | 宽度 | 深度 |
|---|---|---|---|
| user → ui | 帧字节 | 8 | 4096 |
| user → ui | 帧描述符（长度） | 16 | 8 |
| user → ui | 读命令 {rnd, slot} | 9 | 4 |
| ui → user | 帧字节 | 8 | 4096 |
| ui → user | 读描述符 {none, len, slot} | 25 | 4 |
| ui → user | outstanding（槽占用数） | 9（格雷 + 2FF） | — |

## 3. 槽策略（"随机读写"的可判定语义，对应草案 §六.3）

- **槽规格**：4KB × 256 = 1 MB/区（ING/EGR 各一）。帧长 ≤1538 B → 最多 24 拍 ×64 B
  =1536 B < 4096 B，**突发天然不跨 AXI 4KB 边界**（监视器算术复核，见判据）。
- **写**：槽号 = `wm[7:0]`（已提交帧计数）。若该槽仍 FULL（上一帧未被读走）→
  **拒收**（把已进 FIFO 的字节抽掉丢弃，`wr_stall_cnt++`）——**绝不覆盖未读帧**。
- **读 SEQ**：服务"最老未读槽"（指针扫描式定位，与 RND 混用也安全），读完置 EMPTY、指针 +1。
- **读 RND**：命令槽号若越界（`cmd ≥ wm` 且 `wm<256`）→ `ill_rd_cnt++` 并 **clamp 到 wm-1**；
  clamp 后/命令槽不是 FULL（已读或从未写）→ `ill_rd_cnt++` 且**回一个定长 0 的空应答**。
  随机读未写槽从"未定义行为"变成"定义行为 + 可计数"。
- **写等读**：槽满时 `wr_hold` 抬起，上游可暂停（合作式源零丢帧）；
  不合作的源丢帧但被双侧计数（`wr_stall_cnt` / `u_buf_drop`），**差分链闭合**。

## 4. W2 判据与结果（xsim，2026-09-29）

| 用例 | 判据 | 结果 |
|---|---|---|
| T6 | `init_calib_complete`=0 时 **0 个 AXI 拍**、校准后原帧照常落盘读出 | PASS |
| T1 | J2：8 帧（26/33/40/63/100/200/1000/1466 B）逐字节一致 + 槽号对 | PASS |
| T4 | J3：16 个乱序槽命令 → **读出顺序 == 命令顺序**，每帧与槽严格对应 | PASS |
| T5 | J5：越界读 clamp+计数；重读已退休槽/从未驻留槽 → 定长 0 空应答 + 计数 | PASS |
| T2 | J4：300 帧穿过 256 槽区（回绕），无停顿、全部逐字节一致 | PASS |
| T3 | 填满 256 槽后强行写 8 帧：**未读帧一个没被覆盖**、拒收全计数、差分链闭合 | PASS |
| 监视器 | AXI 4KB 边界违规 = 0；协议/长度错误 = 0 | PASS |

最终计数（整轮仿真）：

```
STAT counters: wm=585 wr_frame=585 rd_frame=585 wr_stall=1 ill_rd=3 noframe=0 bresp_err=0
STAT axi:      wr_beats=8202 rd_beats=8202 4k_violation=0 axi_proto_err=0
STAT margin:   user_pushed=586 ui_committed=585 user_drop=8 hold_cycles=24099
STAT service:  wr=933 ui-cycles/frame (3.11 us @300MHz)  rd=920 (3.07 us)  frame period 12.30 us
=== prj10 W2 SIM: PASS (0 errors) ===
```

## 5. 静态预算（W2 实测，替代草案 §九 的估算）

| 项 | 草案估算 | W2 实测 |
|---|---|---|
| 单桥写服务 | ≈0.4–0.7 µs | **3.11 µs/帧**（933 ui 拍，混合帧长，含 8b→512b 逐字节组装） |
| 单桥读服务 | 同上 | **3.07 µs/帧**（920 ui 拍，含 512b→8b 逐字节拆包） |

**修正说明（重要）**：草案 §九 只算了 AXI 突发本身（24 拍 ≈0.16 µs），
**漏掉 8b↔512b 逐字节转换**——那才是内存桥的真实服务时间（≈1466 ui 拍/帧 @300 MHz ≈ 4.9 µs，
实测混合帧长均值 3.1 µs）。结论不变：**读写在同一 ui_clk 域内是并行的两个 FSM，
单桥按 max(3.11, 3.07) ≈ 3.1 µs/帧、两级桥 ≈6.2 µs < 帧周期 12.30 µs**，
节拍器仍是泵B/栈TX（12.21/12.24 µs），**全链路节拍不变**，端到端延迟 +6 µs 量级。
若 ui_clk 实测不是 300 MHz 或上板时序压不进去，此结论需在 W1 用 MIG 生成报告复核。

## 6. bring-up 修掉的真 BUG（三条 RTL + 一条 TB）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | 第一帧写完后所有读卡在 `R_AR`，MIG 模型停在 RS_DATA | **AXI R 通道握手违规**：`rready` 只在 `rvalid` 未到时拉高，`rvalid` 一到就先撤销，从机永远采不到 `rvalid&&rready` | `if (m_axi_rvalid && m_axi_rready)` 才推进（与 AW/W/B 通道一致） |
| 2 | 尾巴帧永远写不完（末拍不满 64 B，FSM 等下一帧的字节填满 → 帧黏连） | 尾拍完成条件只判"满 64 字节" | 增加"帧字节预算耗尽"即完成：`(w_bi==63) || (w_bidx+1==w_len)` |
| 3 | 描述符长度恒为 0 → 所有帧走拒收分支 | `ud_din=wcnt` 组合取自同一拍被清零的 `wcnt` | 独立寄存器 `ud_len_r` 锁存长度 |
| 4 | （TB 记账）槽号/图案整体错位一帧 | T6 送帧后未推进 TB 的 `fid`，槽号与 `flen_of[]` 失配 | T6 后 `fid=1`；RTL 自始正确 |

方法论沉淀：**先做"单帧 + 全内部信号追迹"（`dbg_tb.sv`）再看批量判据**——
本轮 T1–T5 的"内容错一帧"表象，最终定位到 TB 记账而非 RTL；
而 #1/#2/#3 是模型/FSM 层面的真 BUG，靠追迹一次性看清。

## 7. 复现

```powershell
cd D:\FPGA\project_10\sim
powershell -NoProfile -File .\run_sim.ps1     # xvlog -> xelab -> xsim，日志 xsim_run.log
Get-Content .\xsim_run.log | Select-String "SIM:"
# 期望：=== prj10 W2 SIM: PASS (0 errors) ===
```

## 8. 未做 / 不做

- 不建 Vivado 工程、不综合、不实现、不出位流（待拍板后 W3 起）。
- 不接真 MIG：`axi4_ram_model` 是 DDR 替身（含 8 拍读延迟 + 伪随机背压）。
  W3 只把该实例换成 `ddr4_0`。
- 帧侧接口尚未接 泵A/pack/Aurora：W3 的活。
- MicroBlaze/UDP 命令通道实体未建：W2 只到"寄存器 + 命令 FIFO"这一层。
