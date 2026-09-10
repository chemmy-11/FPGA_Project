# FPGA_Project — 毕设 FPGA 工程（工程索引）

多 Agent 协同推理的 FPGA 交换节点：Kintex UltraScale **XCKU060** 实现**标准以太网 + 高速光互连**数据交换（缓存/直通双模式转发），参考 MoA 架构（ICLR 2025）。

**架构定位（2026-09-04 定版）**：端点/上位机通信 = **标准以太网（千兆）**；Aurora 64b/66b = **板间干线**（当前单板不启用，后续接入多块板组交换网络时作为板间 10G 互联）。

## 里程碑

- ✅ **M1（2026-08-11）**：Vitis 导入硬件平台，Hello World 串口打印成功（COM7@9600）
- ✅ **IBERT 物理层（2026-08-27）**：10G PRBS 跨口跳线过纤，PLL Locked + 0E0
- ✅ **Aurora 64b/66b 链路层（2026-08-31）**：内部环回，channel_up/lane_up/误码全 0（ILA）
- ✅ **以太网上位机通道（2026-09-04）**：UDP/ARP/ICMP 栈 + 抓包验证（ping / 回环 / 四包链）
- 🔄 **Aurora-UDP 数据级桥（project_8）**：位流产出 + **时序收敛（WNS=+1.062 ns）**，双 ILA 已插；待上板跑 `udp_verify.py`
- 🔄 **UDP+SFP 前端内环（project_7）**：C17 已修复，待内环验证
- ⏸️ **串口↔Aurora 桥 M-D 验证**：位流在库，挂起
- ⏳ M2 主线后续：DDR（MIG 位流在库）→ DMA → 双模式转发 → 板间干线

## 工程索引

| 目录 | 工程 | 状态 | 说明 |
|---|---|---|---|
| `project_1/` | MicroBlaze 最小系统 | ✅ M1 | BD design_1：MicroBlaze + UART Lite + AXI Interconnect |
| `aurora_64b66b_loop_ex/` | Aurora 64b/66b 例程（+UART 桥） | ✅ 内环验证 ⏸️ 串口桥挂起 | 10G duplex X1Y11；09-02 集成 uart_bridge.v（串口桥位流在库） |
| `ibert_ultrascale_gth_0/` | IBERT 眼图实验 | ✅ 08-27 | 10G PRBS 跨口过纤 0E0（眼图截图待归档） |
| `project_2/` | IBERT 主工程 | 🗄️ 可归档 | 结论已入 ibert 例程 |
| `project_3/` | Aurora IP 主工程 | 📦 在库 | Aurora 64b/66b 定版（10G duplex X1Y11） |
| `project_4/` | MIG/DDR4 验证 | 📦 在库 ⏸️ 搁置 | mig_verify 位流 + AXI4 验证载体；DDR4 4GB 定版完毕 |
| `project_6/` | 以太网 UDP 网口栈 | ✅ 上板验证 09-04 | 官方 39_eth_udp_loop 整包移植；ping/UDP 回环/Wireshark 四包链 |
| `project_7/` | UDP + SFP 前端内环 | 🔄 C17 修复后待验证 | 官方栈 TAP → 帧泵 CDC → PCS/PMA 内环（X1Y8）；`docs\PROGRESS.md` |
| `project_8/` | **Aurora-UDP 数据级桥** | 🔄 位流就绪待上板 | 以太网栈 + Aurora 64b/66b（X1Y11 内环）；`axis_word_pack/unpack` 8↔64 打包 + 双向帧泵；`docs\设计说明_*.md` |
| `0DMA_uart2ddr/` | 旧 DMA 实验 | 🗄️ 归档 | — |
| `scripts/` | Tcl 骨架三件套 | 🛠️ 工具 | create_project / bd_mb_minimal / build / env_check |
| `test/` | 旧测试工程 | 🗄️ 废弃 | — |
| `KU_IO.xdc` `KU引脚表.xlsx` | 官方板卡引脚表 | 📌 参考 | GBK 编码；时钟 AK17 差分 / 复位 AC34 |
| `FMC_4SFP_GTH引脚表.md` | FMC 四光口引脚速查 | 📌 参考 | GT X1Y2；控制脚版本 A |

## 硬件基线（实测定论）

- part = **`xcku060-ffva1156-2-i`（非 CIV）**；100MHz 差分晶振（AK17/AK16）；复位 AC34（低有效）
- 板载网口：双千兆 RGMII（GE1/GE2，YT8531 PHY）；FMC 四光口（GT Quad X1Y2，SFPA=X1Y11，参考钟 T6/T5@156.25MHz）
- JTAG：正点原子 FT2232H；串口 = FT2232H-B 通道（COM7，注册表 SERIALCOMM 实证）

## 标准开发流程

1. Vivado：设计 → 综合/实现 → Generate Bitstream → Export Hardware（含 bitstream）→ .xsa
2. Hardware Manager：Program Device（成功标志 `End of startup status: HIGH`）
3. Vitis：更新 .xsa → Run Configuration **取消 Program FPGA**（保留 Reset entire system）→ Run → 串口 9600
4. 批处理构建：`vivado -mode batch -source <script>.tcl`（幂等脚本见各工程 `scripts\`；⚠️ 需在纯 ASCII 工作目录运行）
