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
- ✅ **真光链路（project_9，2026-09-21）**：双笼 A(Y11)↔B(Y9) 真光路（数据渡光两次）判据全过——ping 20/20 + udp 12/12 + 压力 36/36 + 复测无楔死；帧泵格雷满判根因修复（f7c8be8）
- ✅ **会话 JSON 传输质量评测（2026-09-21）**：质量档 100%+SHA 一致 / 性能档 99.84% @ 19.3 Mbps / 容量档测出系统串行上限 ~23 Mbps（工具 json_storm.py + storm_demo.ps1）
- ⏳ 后续：IBERT 眼图（空闲通道 C/Y10、D/Y8）→ 双板干线 → DDR/DMA 解冻 → 双模式转发 → 性能测量

## 当前推进（2026-09-21）

- ✅ **prj9 真光链路判据全过（09-21，git f7c8be8）**：A(Y11)↔B(Y9) 双 10G 模块 + LC 跳线，数据渡光两次。T23 常亮 + ping 20/20 + udp 12/12 + 压力 36/36 + 复测无楔死，WNS=+1.006ns。
- ✅ **会话 JSON 传输质量评测 + 0.4% 根因定案修复（09-21 晚）**：判决位流（三域 ILA）差分链算术闭合（pack 队列溢出吞 tlast → 帧合并 7×2+9×2=32）；队列 2→16 修复后全量 10MB **100%+SHA 一致**（历史首次）；真实业务传输层 json_reliable.py 交付 100%/0 重传。
- 🔍 帧泵 wr_full 二进制/格雷混比根因修复详见知识库《阶段二之九_prj9_调试记录_帧泵格雷满判_2026-09-21》；全量传输丢失定位证据链见《阶段二之九_prj9_测试报告_会话JSON全量传输质量评测_2026-09-21》。
- ⏭️ 下一步（待导师讨论）：**DDR4 队列缓存收发**（MIG 解冻，路线图待定 #13）；备选 BRAM 帧泵 v2。后续：过载冻结根因（看门狗就位）→ IBERT 眼图 → 双板干线

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
|---|---|---|---|
| `project_9/` | **真光链路版（单笼/双笼 A↔B）** | 🔄 位流就绪，待接线验证 | project_8 全部验证资产复用（含 rgmii_rx_fix2 IDELAY 1250ps），loopback 3'b010→3'b000；双笼版架构见上文"当前推进" |

### ⏸️ 挂起（位流在库，恢复即用）

| 目录/课题 | 挂起时间 / 原因 | 恢复触发 |
|---|---|---|
| `project_4/` MIG/DDR4 验证 | 08-31（决策 #5，导师指示先做网口+SFP） | DDR 解冻 / 做缓存转发与 DMA 对接 |
| `aurora_64b66b_loop_ex/` 串口桥 M-D 三级验证 | 09-04：链路健康但桥出复位 | 解 dbg 探针时钟域 undefined + AE33 输入方向 |
| `project_7/` UDP+SFP 前端内环 | 09-04（决策 #10，架构定版后让位数据级桥） | 光电转/带 SFP 口交换机到位，或多端点形态复用 |
| 8b/10b 裸调 GT 练手 | 08-27（决策 #2，物理层已由 IBERT 覆盖） | 需要裸层参照（Aurora 排障）或答辩补充 |

### 🗄️ 归档 / 工具

| 目录 | 说明 |
|---|---|
| `project_2/` | IBERT 主工程（结论已入 ibert 例程） |
| `project_3/` | Aurora IP 主工程（64b/66b 定版 xci：10G duplex X1Y11） |
| `0DMA_uart2ddr/` | 旧 DMA 实验（DDR 搁置期间预研） |
| `scripts/` | Tcl 骨架三件套：create_project / bd_mb_minimal / build / env_check |
| `KU_IO.xdc`（根） · `docs/KU引脚表.xlsx` | 官方板卡引脚表（GBK 编码；时钟 AK17 差分 / 复位 AC34） |
| `docs/参考_cross_FMC_4SFP_GTH引脚表_2026-08-27.md` | FMC 四光口引脚速查（GT Quad X1Y2：A=X1Y11、B=X1Y9、C=X1Y10、D=X1Y8；控制脚版本 A） |
| `docs/` | **文档中心**：操作文档脱敏快照（含挂起区）+ 交接/参考/里程碑文档；命名规范 `[阶段]_prj标识_概要_YYYY-MM-DD`（见 `docs/README.md` 与 `AGENTS.md`「文档规范」） |

## 硬件基线（实测定论）

- part = **`xcku060-ffva1156-2-i`（非 CIV）**；100MHz 差分晶振（AK17/AK16）；复位 AC34（低有效）
- 板载网口：双千兆 RGMII（GE1/GE2，YT8531 PHY）；FMC 四光口（GT Quad X1Y2，A=X1Y11，参考钟 T6/T5@156.25MHz）
- JTAG：板载 FT2232H；本机调试烧录走 Digilent USB-JTAG（210512180081，hw_server 自动识别）；串口 = FT2232H-B 通道（COM7，注册表 SERIALCOMM 实证）

## PC 侧验证三板斧（判据闭环）

```powershell
# 0) 断电重上电后位流易失 → 重烧（成功标志 PROGRAM_OK + 两行 时钟在跑）
& 'D:\Xilinx\Vivado\2023.1\bin\vivado.bat' -mode batch -source D:\FPGA\project_9\scripts\program_board.tcl
# 1) 链路：T23 常亮（channel_up / link_ok 硬门控）
# 2) 通路：
ping 192.168.1.10 -n 20          # 0% 丢包、全 <1ms
# 3) 数据（⚠️ 先关占用 1234 端口的程序）：
$env:PYTHONUTF8 = 1              # 必须！GBK 控制台打 ✓ 会崩
cd D:\FPGA\project_9
python scripts\udp_verify.py    # 回显一致 12/12（长度覆盖 帧长%8 全部余数类）
```

佐证：Wireshark 过滤 `udp.port==1234`，请求/回显成对且 payload 相同。三层证明力：T23=链路、ping=通路、udp_verify=数据完整性。

## 标准开发流程

1. Vivado：设计 → 综合/实现 → Generate Bitstream → Export Hardware（含 bitstream）→ .xsa
2. Hardware Manager：Program Device（成功标志 `End of startup status: HIGH`）
3. Vitis：更新 .xsa → Run Configuration **取消 Program FPGA**（保留 Reset entire system）→ Run → 串口 9600
4. 批处理构建：`vivado -mode batch -source <script>.tcl`（幂等脚本见各工程 `scripts\`；⚠️ 需在纯 ASCII 工作目录运行）

---

*状态以本文件 + git log 为准；里程碑判定与决策记录详见知识库《长期路线图 v4.1》。*