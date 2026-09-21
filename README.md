# FPGA_Project — 毕设 FPGA 工程（工程索引）

多 Agent 协同推理的 FPGA 交换节点：Kintex UltraScale **XCKU060** 实现**标准以太网 + 高速光互连**数据交换（缓存/直通双模式转发），参考 MoA 架构（ICLR 2025）。

**架构定位（2026-09-04 定版）**：端点/上位机通信 = **标准以太网（千兆）**；Aurora 64b/66b = **板间干线**（单板阶段用于数据级验证，接入多块板组交换网络时作为板间 10G 互联）。

> **给 Agent/协作者**：工程规范（事实源优先级、硬件事实卡、CDC/ILA/XDC 规范、调试方法论、坑账本）见 [`AGENTS.md`](AGENTS.md)。

## 里程碑

- ✅ **M1（2026-08-11）**：Vitis 导入硬件平台，Hello World 串口打印成功（COM7@9600）
- ✅ **IBERT 物理层（2026-08-27）**：10G PRBS 跨口跳线过纤，PLL Locked + 0E0（眼图已归档）
- ✅ **Aurora 64b/66b 链路层（2026-08-31）**：内部环回，channel_up/lane_up/误码全 0（ILA）
- ✅ **以太网上位机通道（2026-09-04）**：UDP/ARP/ICMP 栈 + 抓包验证（ping / 回环 / 四包链）
- ✅ **M2 数据级桥（2026-09-18）**：PC UDP 数据穿越 Aurora 64b/66b 编解码往返——ping 10/10+20/20 全 <1ms、udp_verify 12/12 + 压力 36/36 逐字节一致；三根因（unpack 断流 / 帧泵 rd_empty off-by-one / RGMII RX 采样相位）全部修复闭环
- 🔄 **当前推进：真光链路（project_9）**——去内环（loopback 3'b000）+ 双笼 A↔B 版位流已产出（WNS=+1.008ns），待接线验证
- ⏳ 后续：IBERT 眼图（空闲通道 C/Y10、D/Y8）→ 双板干线 → DDR/DMA 解冻 → 双模式转发 → 性能测量

## 当前推进（2026-09-20）

- ✅ **prj9 双笼真光链路判据全过（09-20，git f7c8be8）**：A(Y11)↔B(Y9) 双 10G 模块 + LC 跳线，数据渡光两次。判据：T23 常亮 + ping 20/20 + udp_verify 12/12 + 压力 36/36 + 复测 ping 10/10（无楔死），WNS=+1.006ns。
- 🔍 本轮根因：帧泵 wr_full 二进制/格雷混比，累计字节跨 2048 回绕后永久伪满（25 帧后全路径楔死）。仿真复现+修复验证（`project_9/sim/`），详见知识库《调试记录_prj9_帧泵格雷满判_2026-09-20》。
- ⏭️ 下一步：IBERT 眼图观测（同 quad 空闲通道 C/D，或换装位流）→ 双板干线 → DDR/DMA 解冻

## 工程索引（状态一览）

### ✅ 已完成

| 目录 | 工程 | 达成 | 说明 |
|---|---|---|---|
| `project_1/` | MicroBlaze 最小系统 | ✅ M1（08-11） | BD design_1：MicroBlaze + UART Lite + AXI Interconnect |
| `ibert_ultrascale_gth_0/` | IBERT 眼图实验 | ✅ 08-27 | 10G PRBS 跨口过纤 0E0；眼图截图已归档 |
| `aurora_64b66b_loop_ex/` | Aurora 例程 + UART 桥 | ✅ 08-31 内环验证 | 10G duplex X1Y11；`uart_bridge.v`（串口桥位流在库，验证挂起见下） |
| `project_6/` | 以太网 UDP 网口栈 | ✅ 09-04 上板验证 | 官方 39_eth_udp_loop 整包移植；ping/UDP 回环/Wireshark 四包链 |
| `project_8/` | **Aurora-UDP 数据级桥** | ✅ **M2（09-18）判据全过** | 以太网栈 + Aurora 64b/66b（X1Y11 内环）；axis_word_pack/unpack 8↔64 打包 + 双向帧泵；`rtl/*_dly.v` = IDELAY 1250ps 修复版；三根因排障脚本与 ILA 捕获数据在 `scripts/`；`docs\设计说明_*.md` |

### 🔄 正在推进

| 目录 | 工程 | 状态 | 说明 |