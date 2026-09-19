---
type: 操作文档
摘要: 阶段二之四——UART 串口↔Aurora 上下位机验证实操单：自写 UART+帧适配+Aurora 桥，PC 侧三级验证（文本回显/文件回环/自动化压测）
阶段: 阶段 2.5（导师插入：上下位机通信 + 验证 SFP 传输，无 DDR）
目标: PC 串口发送文件经 UART→Aurora(内部环回)→UART 原样收回，1MB 逐字节比对一致
created: 2026-08-31
updated: 2026-09-10
related: "[[操作文档/阶段二之三_Aurora64b66b环回实操单]] · [[长期路线图_2026-09-04]] · [[短期待办]]"
---

# 阶段二之四 · UART↔Aurora 上下位机验证（配置定版卡）

> ⏸️ **状态（2026-09-10 归档）：挂起**——链路层已证健康（新位流 ILA：channel_up=1 / lane_up=1 / 零误码），但桥出复位；§5 的 PC 侧三级验证（M-D）尚未开跑。恢复入口见 [[操作文档/挂起/README]]。

> 🎯 **定位**：导师本质要求 = **上下位机通信 + 验证 SFP 传输**（路线图决策 #6）——串口先行（网口 ATK91131A/RGMII 推迟至多 Agent 联调前）。
> **验证金字塔逻辑**：物理层已由 IBERT 外环覆盖（真实光路）；本步在**内部 PMA 环回**下验证"Aurora 协议栈 + 上下位机数据链"，两者合成全链路证据。
> **分工**：PL 侧 RTL/构建归我（已委托）；PC 侧操作归你。预计：RTL 1h + 编译 30min + PC 验证 30min。

---

## 0. 第一性原理

1. **上下位机通信**需要 PC↔FPGA 双向字节通道 → FT2232H 自带 USB-UART（M1 的 COM7，零新增硬件）；
2. **验证 SFP 传输正确性**需要数据走 Aurora 并可靠返回 → 复用已验证的 Aurora 配置（duplex/X1Y11/内部 PMA 环回）；
3. **串口带宽 11.5KB/s 只验正确性不验吞吐**——吞吐数据由 Aurora PRBS/后续网口/联合调试承担（决策 #6 已声明）；
4. **为什么需要帧适配**：UART 是裸字节流，Aurora framing 按 tlast 分帧——直接把 UART 字节推入会造成跨帧粘连/帧长不可控。方案：**长度前缀微协议**——UART 字节流被组装成 `[len8][payload×len]` 定长块，帧边界可控，对端可校验完整性。

## 1. 架构

```
PC 串口终端(COM7, FT2232H-B, 115200 8N1)
   │ USB
   ▼
FT2232H-B ──▶ UART RX(板载 AE33/AF34 对,M1 已实证) ──▶ 帧适配(组块) ──▶ Aurora TX
                                                                        │ PMA 内部环回
PC ◀── UART TX ◀── 帧恢复(拆块+计数) ◀── Aurora RX ◀────────────────────┘
```

## 2. RTL 组件定版（我实现）

| 组件 | 定版 | 为什么 |
|------|------|--------|
| UART 收发器 | 自写，16× 过采样，115200 8N1（结构上支持 921600 切换） | 裸字节流入口/出口；自写比 IP 轻（无 AXI 依赖） |
| 帧适配 | `[len8][payload×len]`，len=0 视为 keep-alive | 帧边界可控 + 完整性可校验 |
| Aurora | 复用已验证配置（duplex/X1Y11/内部 PMA 环回 `loopback=3'b010`） | 链路层已闭环（阶段二之三） |
| ILA | ui_clk 域：aurora_rx_valid/帧计数/块计数/err | 双端观测用（隔离矩阵见 §6） |
| LED | T22=aurora channel_up，T23=帧回环活动 | 肉眼先判链路 |

## 3. 引脚

- UART 球对 = **AE33/AF34**（M1 串口通信已实证的同一对，官方 KU_IO.xdc 同源）；LVCMOS33；方向（TX/RX 与 FT2232H-B 的对应）实现时按 M1 design_1 约束照抄；
- 其余（sys_clk/reset/LED）沿用 Aurora 卡的定版。

## 4. 构建流程（我接管）

新工程 `project_5`（uart_aurora_bridge）→ 复用 Aurora IP 参数（同阶段二之三定版）→ 自写 RTL 入工程 → 直插 ILA → 批处理出位流 → 复核三件套。

## 5. PC 侧验证三级（你操作）

### L1 · 文本回显（冒烟）
串口终端（XCOM/SSCOM/MobaXterm 均可）开 **COM7 @115200 8N1 无流控** → 打字 → 原样回显。乱码=波特率/帧滑（发我）。

### L2 · 文件回环比对（半严格）
1. 生成 **64KB 随机文件**（随机数据才能暴露帧错位）；
2. 串口助手十六进制模式发送 → 接收窗口另存为文件；
3. `fc /b 原文件 收文件` 二进制比对——**逐字节一致**（115200 下约 11 秒）。

### L3 · 自动化压测（最严格）
```python
import serial, os, time
PORT, BAUD, N = 'COM7', 115200, 1_000_000      # 1MB 压测
data = os.urandom(N)
s = serial.Serial(PORT, BAUD, timeout=2); s.reset_input_buffer()
t0 = time.time(); s.write(data); rx = s.read(N); dt = time.time()-t0
ok = rx == data
first = next((i for i,(a,b) in enumerate(zip(data,rx)) if a!=b), '无')
print(f"{'PASS' if ok else 'FAIL'}: {N}B, {dt:.1f}s, {N/dt:.0f} B/s, 首错位 {first}")
```
- **判据**：1MB `PASS` → 提速 **921600** 复测 `PASS` → 双档通过。

## 6. 故障隔离矩阵（PC 侧现象 × 板上 ILA = 定位）

| PC 侧现象 | ILA 看 | 结论 → 段 |
|-----------|--------|----------|
| 无回显；Aurora 帧进出正常 | channel_up=1、计数走 | 串口段坏（UART/波特率） |
| 无回显；Aurora TX 有进无出 | 内环未生效/up=0 | SFP 链路段（发我） |
| 乱码；Aurora 零误码 | 误码=0 | 帧适配/CDC bug（我修） |
| 乱码；误码计数>0 | 误码涨 | 链路位错（降波特率重试） |

## 7. 判据与归档

- [ ] L1 文本回显 ✅
- [ ] L3 1MB@115200 `PASS` ✅
- [ ] 921600 复测 `PASS` ✅
- [ ] ILA 波形 + 脚本输出截图 → `D:\FPGA\uart_sfp\docs\`

达成 = **上下位机通信 + SFP 数据传输双验证闭环**（导师本质要求达成）。

## 8. 坑位速查

| 症状 | 先查 |
|------|------|
| 两个 COM 分不清 | FT2232H-A=JTAG（设备管理器带 "USB Serial Port"×2），M1 实证 COM7=UART；试错零成本 |
| 回显缺字节/粘连 | 帧适配 len 域与载荷错位（我的 RTL）；PC 端发送间隙 |
| 高波特率误码涨 | FT2232H 与 PLL 分频的时钟容差——降回 115200 先保判据 |
| channel_up 不亮 | 复用阶段二之三坑位表（loopback/refclk/引脚） |

---

*参谋位置：PL 侧我交付位流后，你按 §5 走；任何现象配 ILA 截图一起发我。*
