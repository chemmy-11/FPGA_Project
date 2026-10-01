# FPGA_Project — FPGA 高速互联网络平台

基于正点原子 KU060 开发板（Kintex UltraScale `xcku060-ffva1156-2-i`）搭建的多节点数据交换平台：

- **端点接入**：PC / 树莓派等标准以太网设备，经板载千兆 RJ45 网口接入
- **板间干线**：Aurora 64b/66b 协议跑 10G 光纤（SFP+ 光口），多板互联时作为高速骨干
- **板内转发**：数据可直通转发，也可整帧写入 DDR4 缓存后按需读出（大容量排队，拥塞调度的基础）

目标场景是边缘侧多节点协作推理：多块板子组成交换网络，承载节点间的大块数据（如模型分片、会话记录）传输。

> 面向协作者：工程规范（事实源优先级、CDC/ILA/XDC 约定、调试方法论、坑账本）见 [`AGENTS.md`](AGENTS.md)。本 README 是入门第一份文档。

## 硬件平台

| 项 | 事实 |
|---|---|
| FPGA | Kintex UltraScale `xcku060-ffva1156-2-i` |
| 系统时钟 | 100 MHz 差分（AK17/AK16）；复位按键 AC34（低有效） |
| 网口 | 双千兆 RGMII（YT8531 PHY），默认 GE1：PC `192.168.1.102` ↔ 板 `192.168.1.10` |
| 光口 | FMC 四 SFP+ 笼（GT Quad X1Y2：A=X1Y11、B=X1Y9、C=X1Y10、D=X1Y8），参考钟 156.25 MHz |
| 调试 | Digilent USB-JTAG 烧录；FT2232H 串口（COM7 @9600） |
| 环境 | Vivado 2023.1；Python 3.10+（Windows 控制台需设 `PYTHONUTF8=1`） |

## 工程血缘

每个新工程只复用**已上板验证通过**的前序部件，官方例程永远是最高事实基准。箭头表示文件与验证资产的继承关系：

```
正点原子 KU060 官方例程库（本仓库全部工程的事实基准）
│
├─[例程39章 以太网UDP]──► project_6   千兆以太网 UDP 协议栈
│        │               ARP / ICMP / UDP 收发回显，ping 0% 丢包
│        │               ✅ 上板验证 2026-09-04
│        │               （含 rgmii_rx_fix2：千兆 RGMII 接收采样时序修复）
│        ▼
│    project_7   SFP 光口承载以太网（内环验证）
│        │       ⏸ 已封存 —— 端点接入统一改用 RJ45 网口后，此路线不再需要
│        │
│        │       帧缓冲泵 frame_fifo_pump 在本工程诞生：
│        │       整帧缓存 + 跨时钟域搬运，此后成为所有数据通路的标配部件
│        ▼
├─[Aurora 64b/66b 例程]─┬► aurora_64b66b_loop_ex   官方例程留档 ⏸
│  （时钟/复位/QPLL      └► project_3   Aurora 64b/66b 链路层（GT 内环）
│   支撑逻辑随工程走）         channel_up / 零误码 ✅ 2026-08-31
│                                   │
│                                   ▼
│                             project_8   Aurora-UDP 桥接
│                             以太网帧穿过 Aurora 64b/66b 编解码后原样返回，
│                             payload 逐字节一致 ✅ 2026-09-18
│                             （= 例程39章协议栈 + Aurora例程支撑逻辑
│                                + project_7 的帧缓冲泵，三者首次合体）
│                                   │
│                                   ▼
│                             project_9   真实光纤链路验证
│                             两个 SFP+ 光口 A↔B 用光纤对接，数据渡光纤往返，
│                             10MB 文件 100% 到达 + SHA256 完全一致 ✅ 2026-09-21
│                                   │
│                                   └─fork──► project_10   DDR4 帧队列（开发中）
│                                                 "内存进环路"：以太网帧写入 DDR4
│                                                 再按帧读出，为大容量排队打地基；
│                                                 复用 project_9 全套数据通路
│                                                 🔄 逻辑与时序预检已收敛，待上板联调
│                                                 ▲
├─[MIG 例程]──► project_4   MIG DDR4 读写校准 ────┘
│               🔄 校准复验待上板；向 project_10 提供 DDR4 控制器
│
└─[MicroBlaze 例程]──► project_1   MicroBlaze 软核最小系统 ✅ 2026-08-11
                       跑通 FPGA 内软核 + Vitis 软件开发流；
                       将来作为控制面（状态上报 / 队列配置）回归 project_10
```

**图例**：✅ 已上板验证闭环 · ⏸ 封存（保留入库，不再推进）· 🔄 进行中

图外挂起支线：project_2（8b/10b 编解码练手，仅起步即跳过——物理层信号质量已由 IBERT 眼图实验覆盖，2026-08-27）；串口调试桥（在 `aurora_64b66b_loop_ex/` 例程目录内，上位机验证资料未收到）。

## 工程一览

| 目录 | 内容 | 验证判据（怎么算"过"） | 状态 |
|---|---|---|---|
| `project_1/` | MicroBlaze 软核最小系统 | 串口打印 Hello World | ✅ 2026-08-11 |
| `project_3/` | Aurora 64b/66b IP 配置定版 | GT 内环 channel_up、零误码 | ✅ 2026-08-31 |
| `project_4/` | MIG DDR4 读写校准 | 校准完成 + 读写数据比对零误码；位流已产出 | 🔄 校准复验待上板 |
| `project_6/` | 千兆以太网 UDP 协议栈 | ping 0% 丢包、UDP 回显逐字节一致、Wireshark 抓包核对 | ✅ 2026-09-04 |
| `project_8/` | Aurora-UDP 桥接 | PC 发 UDP → 穿 Aurora 编解码往返 → payload 逐字节一致 | ✅ 2026-09-18 |
| `project_9/` | 真实光纤链路全链路 | 光口 A↔B 对接，10MB 文件 100% 到达 + SHA256 一致 | ✅ 2026-09-21 |
| `project_10/` | DDR4 帧队列（内存进环路） | 仿真六用例全过；真 MIG 综合时序收敛；上板联调待做 | 🔄 开发中 |
| `project_2/` | 8b/10b 编解码练手（仅起步即跳过，物理层由 IBERT 实验覆盖） | — | ⏸ 封存 |
| `project_7/` | SFP 光口以太网前端 | — | ⏸ 封存 |
| `aurora_64b66b_loop_ex/` | Aurora 官方例程 + 串口调试桥 | 例程内环已验证；串口桥验证未完成 | ⏸ 留档 |
| `ibert_ultrascale_gth_0/` | IBERT 物理层实验 | 10G PRBS 过纤零误码 + 眼图 | ✅ 2026-08-27 |
| `0DMA_uart2ddr/` | MicroBlaze+MIG+DMA+UART 参考设计（Vivado 2019.2） | **未验证**，仅作参考骨架 | 🗄️ 归档 |

## 快速开始（以 project_9 为例复现三层验证）

一块 KU060 板 + 一根网线 + 一根 LC 光跳线（把光口 A、B 对接），三层判据依次证明"链路在 → 通路通 → 数据对"：

```powershell
# 1) 烧录位流（断电后位流易失，需重烧；脚本幂等）
& 'D:\Xilinx\Vivado\2023.1\bin\vivado.bat' -mode batch -source D:\FPGA\project_9\scripts\program_board.tcl

# 2) 链路层：板上 T23 LED 常亮 = Aurora 双通道链路建立（channel_up 硬门控）

# 3) 网络层：ping 板卡
ping 192.168.1.10 -n 20          # 判据：0% 丢包、全部 <1ms

# 4) 数据层：UDP 回显校验（先关掉占用 1234 端口的程序）
$env:PYTHONUTF8 = 1              # Windows 控制台必设，否则中文输出崩
cd D:\FPGA\project_9
python scripts\udp_verify.py     # 判据：回显一致 12/12
```

大文件完整性验证（数据真实穿过光纤往返）：`python scripts\json_storm.py <任意文件> --out recv.bin`，比对重组文件与源文件 SHA256。

各工程 `scripts\` 下均有 `create_project / build / program` 幂等脚本，可在纯 ASCII 路径下一键重建工程。

## 仓库结构

```
project_N/          各 Vivado 工程（rtl / sim / scripts / xdc / docs）
aurora_64b66b_loop_ex/  Aurora 官方例程留档
ibert_ultrascale_gth_0/ IBERT 眼图实验工程
0DMA_uart2ddr/      MicroBlaze+DDR4+DMA 参考设计（未验证）
docs/               文档中心：各工程的实操单、测试报告、调试记录（脱敏快照）
AGENTS.md           工程规范：事实源优先级、硬件事实卡、CDC/ILA/XDC 约定、坑账本
KU_IO.xdc           官方板卡引脚约束（事实基准）
scripts/            顶层 Tcl 骨架
```

## 开发约定

1. **官方例程 > 已上板验证的工程 > 板卡手册 > AI 生成内容**——冲突时按此优先级裁决。
2. **官方文件不改动原件**：修复一律走"同名模块顶替"或"派生新文件"。
3. **结论必须有判据**：每个"通过"都要落到可复现的证据（计数器对账 / 哈希比对 / 抓包），不接受"看起来能跑"。
4. Vivado 相关路径全 ASCII（中文路径有 GBK 编码实坑）。
5. 文档命名：`[阶段]_[工程]_[概要]_[日期].md`，详见 `docs/README.md`。

---

*各工程详细验证过程与排障记录见 `docs/`；工程状态以本文件与 git log 为准。*
