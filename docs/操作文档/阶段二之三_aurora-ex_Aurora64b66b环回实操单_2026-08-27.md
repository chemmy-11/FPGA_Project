---
type: 操作文档
摘要: Aurora 64b/66b 环回验证实操单——第一性原理推导每个参数、IP 配置定版表、可粘贴 XDC、判据与坑位
阶段: 阶段二（M2 主线第 1 步）
目标: Aurora duplex 单 lane 10G 环回，channel_up + lane_up + 误码计数 0 + ILA 数据流
created: 2026-08-27
updated: 2026-08-27
related: "[[操作文档/阶段二_SFP收发与Aurora64b66b]] · [[操作文档/阶段二前置_IBERT眼图自检实操单]] · [[笔记和开发指南/光纤接口8b10b]] · [[短期待办]]"
---

# 阶段二之三 · Aurora 64b/66b 环回验证（配置定版卡）

> 🎉 **实验状态：✅ 上板验证通过（2026-08-31）**——近端 PMA 内部串行环回下 ILA 实测：`channel_up=1`、`lane_up=1`、`hard_err=0`、`soft_err=0`、`data_err_count=0`、`rx_tvalid=1`，两颗状态灯（T22=CHANNEL_UP、T23=LANE_UP）点亮。物理层已由 IBERT 外环覆盖（2026-08-27，真实光路），全链路证据将在联合调试阶段自然产生。**M2 第 1 步闭环 → 下一步：AXI 总线族。**
>
> **定位**：M2 主线（物理层已由 IBERT 验证 ✅）。手册《阶段二_SFP收发与Aurora64b66b》给流程骨架，本卡给**定版参数**——每个参数从第一性原理推出来，不抄手册截图。
> **进度（2026-08-31）**：IP 配置生成 + xci 终验 ✅ → 例程生成 + 板卡适配补丁 ✅（LED→T22/T23、init_clk→AK17/AK16、复位内部拉零、sfp 控制已加、7 条 mark_debug、XDC 已适配）→ Set Up Debug 8 探针 ✅ → **物理环路方案调整**：实验室现有接法为跨口互连（SFPA↔SFPB / SFPC↔SFPD，IBERT 四通道专用），单通道 duplex 不适用 → 已启用**近端 PMA 内部串行环回（`loopback_i=3'b010`）**，无需光纤/模块即可验证协议栈全层 → 当前步：重综合 + 重做 Set Up Debug + 实现位流 + 上板看 channel_up。
> **决策（2026-08-31，用户确认）**：不再单独做 Aurora 真实光路外环——物理层已由 IBERT 外环（真实光路）验证，"Aurora 数据跑真实光纤"的证据将在联合调试阶段（DMA→Aurora→SFP+ 全链路）自然产生。单口自环头降级为可选项。
> **分工**：GUI 点击/上板归你；异常发我判读。预计：IP 配置 30min + 补丁 1h + 编译 20-40min + 上板 30min。

---

## 0. 第一性原理推导链（答辩直接用）

| # | 需求/约束 | 推导 | 落到的参数 |
|---|----------|------|-----------|
| 1 | 光纤只传串行比特流，不传时钟 | 必须线路编码：密集跳变供 CDR 提取时钟 + 直流平衡 | 64b/66b（开销 3.03%，vs 8b/10b 的 20%） |
| 2 | 板上 SFP+ 为 10G 档，IBERT 已实测 10G 物理可跑 | 线速率定 10G | **Line rate = 10 Gbps** |
| 3 | 10G 超出 CPLL 频段（~2-6.25G） | 必须 QPLL（9.8-16.375G 档） | **GT PLL = QPLL0** |
| 4 | QPLL 倍频要干净（整数分频比） | 10G ÷ 156.25M = **64**（整数）✓ | **GT RefClk = 156.25 MHz**（板上实测时钟恰好满足——156.25 与 64b/66b 是天生一对） |
| 5 | 有效带宽账本 | 10G × 64/66 = **9.697 Gbps** 有效 → 64-bit 界面 → 用户时钟 10G/66 ≈ **151.52 MHz** | **UI 宽度 64-bit**（对齐任务分工"10G→64-bit" AXI-Stream 契约） |
| 6 | 环回验证要同收发 | 单核同时含 TX/RX | **Dataflow = Duplex** |
| 7 | 后续 DMA/缓存转发需要帧边界（tlast）语义 | 裸流没有帧概念 | **Interface = Framing** |
| 8 | GT 未锁定时初始化状态机就要跑 | init clock 必须独立于恢复时钟 → 用板载现成时钟 | **Init clock = 100 MHz**（AK17/AK16 差分，官方 KU_IO.xdc 同源） |
| 9 | 10G ≤ 单通道 16.375G 上限 | 无需多 lane 绑定 | **Lanes = 1**（免 channel bonding 复杂度） |
| 10 | 物理层三项已实测定案 | 直接继承 IBERT 战果 | 通道 **X1Y11**(SFPA) / **MGTREFCLK1_226**(T6/T5) / **版本 A** 控制脚 |

## 1. IP 配置定版表（IP Catalog → Aurora 64B/66B）

> ⚠️ GUI 字段名以 2023.1 实际显示为准；对不上的字段发截图我校对。

| 配置项                     | 定版值                        | 为什么（对应 §0 条目）                                                                                      |
| ----------------------- | -------------------------- | -------------------------------------------------------------------------------------------------- |
| Component Name          | `aurora_64b66b_0`          | —                                                                                                  |
| Dataflow                | **Duplex**                 | #6                                                                                                 |
| Line rate               | **10 Gbps**                | #2                                                                                                 |
| GT RefClk (MHz)         | **156.25**                 | #4                                                                                                 |
| Interface               | **Framing**                | #7                                                                                                 |
| Init clock (MHz)        | **100**                    | #8                                                                                                 |
| Lanes                   | **1**                      | #9                                                                                                 |
| User interface width    | **64-bit**                 | #5                                                                                                 |
| Flow Control            | **None**                   | 首次 bring-up 最简；缓存转发靠本地缓冲兜底（基线工程若用了 UART/TC 流控，对照后再改）                                               |
| CRC                     | 不勾（首版）                     | 少一个调试变量；链路稳后可加 CRC32                                                                               |
| Endianness              | Little（默认）                 | 与 AXI 默认一致                                                                                         |
| Shared Logic            | 默认（in example design）      | 时钟复位资源放例程，好改                                                                                       |
| GT Location（Location 页） | quad **X1Y2**，通道 **X1Y11** | #10；⚠️ 若 refclk 下拉看不到 **T6/T5** 的 MGTREFCLK1 = 位置选错（认 Bank 226 + Data pins **R3/R4**=SFPA，不认 X 编号） |
| GT PLL                  | **QPLL0/1 皆可（IP 求解器自选）**    | #3；✅ 实测生成 **QPLL1**：FBDIV=64 → 156.25M×64=10.000G 精确解；xci 的 `C_PLL_TYPE=LCPLL` 是标签噪音，忽略 |
| 极性反转类选项                 | 全不勾                        | IBERT 0E0 已证极性正确                                                                                   |
| Scrambler / CB·CC       | 无开关/自动                     | 64b/66b 内建扰码；时钟补偿由协议层自动做（正是 8b/10b 笔记里"GT 级时钟纠正的上层版"）                                              |

### ✅ 生成物终验（2026-08-31，xci + 生成 RTL 双证，全部通过）

| 项 | 生成物证据 |
|----|----------|
| 线速率 10G | `c_line_rate=10`；**QPLL1_FBDIV=64 → 156.25M×64=10.000 GHz** |
| 参考时钟 T6/T5 | `C_REFCLK_LOC_P/N = T6/T5`，`C_REFCLK_SOURCE=MGTREFCLK1_of_Quad_X1Y2` |
| 位置 X1Y2/X1Y11 | `C_START_QUAD=Quad_X1Y2`、`C_START_LANE=X1Y11`、TX/RX_MASTER_CHANNEL=X1Y11 |
| Duplex/Framing/None/无CRC/无USER_K/DRP=AXI4-Lite | `dataflow_config`/`interface_mode`/`flow_mode`/`crc_mode`/`c_user_k`/`drp_mode` 全符 |
| **UI 64-bit** | `s_axi_tx_tdata[0:63]`、`m_axi_rx_tdata[0:63]`；内部通路 INT_DATAWIDTH=1（4字节/66bit） |
| part | xcku060/ffva1156/-2（非 CIV） |

📌 备忘：① `tdata [0:63]` 大端位序 = "Little Endian Support 未勾"的体现，环回无影响、DMA 集成时留心；② xci `C_COLUMN_USED=left` 与 GUI "right" 标签分歧——物理锚点（X1Y2/X1Y11/T6T5）全对，纯命名噪音。

**与基线工程对照（2026-08-27 已核对；基线仓库无 .xci，依据 = 框图端口清单 [[8.3/2026-04-30/block_diagram]] + SW 代码）**：

| 项                          | 基线工程（ZCU102）                                                                             | 本卡定版              | 裁决                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------- |
| 核形态                        | **2× simplex**（aurora_64b66b_0 纯 TX 挂 USER_DATA_S_AXIS_TX；_1 纯 RX 挂 USER_DATA_M_AXIS_RX） | **1× duplex**     | 基线为板间主从（SW 分 dma_master/dma_slave 两角色）；我们单板自环验证 + 缓存/直通双模式都要同口收发 → duplex |
| Interface                  | **Framing**（reset2fg/reset2fc 证明 frame_gen/check 在 BD 内）                                 | Framing           | ✅ 一致                                                                      |
| refclk 进核                  | util_ds_buf（IBUFDS_GTE3）后共享给两核                                                           | 例程自带同构            | ✅ 一致                                                                      |
| init_clk                   | 外部输入（两核各有 init_clk 端口）                                                                   | 外部 100MHz（AK17）   | ✅ 一致                                                                      |
| 状态观测                       | CORE_STATUS / CORE_CONTROL / gt_powergood / link_reset_out                               | ILA 抓同类信号         | ✅ 一致                                                                      |
| 跨时钟域                       | 每侧 1 个 AXI4-Stream Data FIFO（带 data_count）                                               | 验证阶段不需要           | M2 后半接 DMA 时照此加（对应任务分工"跨时钟域 FIFO 归属"契约）                                   |
| Flow Control / UI 位宽 / CRC | 框图无法看出                                                                                   | None / 64-bit / 无 | 按第一性原理定版；后续集成如遇吞吐或反压问题再评估                                                 |

## 2. 可粘贴 XDC（例程生成后追加；端口名以例程顶层实际为准）

```tcl
## ===== GT refclk: MGTREFCLK1_226 (T6/T5) 156.25MHz =====
## 若例程自带 refclk 约束则核对球号，勿重复添加
set_property PACKAGE_PIN T6 [get_ports gt_refclk_p]
set_property PACKAGE_PIN T5 [get_ports gt_refclk_n]
create_clock -period 6.400 -name gt_refclk [get_ports gt_refclk_p]

## ===== init clock: onboard 100MHz diff (AK17) =====
set_property -dict {PACKAGE_PIN AK17 IOSTANDARD DIFF_HSTL_I_12} [get_ports init_clk_p]
set_property -dict {PACKAGE_PIN AK16 IOSTANDARD DIFF_HSTL_I_12} [get_ports init_clk_n]
create_clock -period 10.000 -name init_clk [get_ports init_clk_p]

## ===== FMC_4SFP control signals, VERSION A =====
set_property -dict {PACKAGE_PIN H26  IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[0]}]
set_property -dict {PACKAGE_PIN AH12 IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[1]}]
set_property -dict {PACKAGE_PIN J25  IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[2]}]
set_property -dict {PACKAGE_PIN AF12 IOSTANDARD LVCMOS33} [get_ports {sfp_tx_disable[3]}]
set_property -dict {PACKAGE_PIN G27  IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[0]}]
set_property -dict {PACKAGE_PIN AH11 IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[1]}]
set_property -dict {PACKAGE_PIN M26  IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[2]}]
set_property -dict {PACKAGE_PIN AF13 IOSTANDARD LVCMOS33} [get_ports {sfp_rs0[3]}]
set_property -dict {PACKAGE_PIN H27  IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[0]}]
set_property -dict {PACKAGE_PIN AG11 IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[1]}]
set_property -dict {PACKAGE_PIN M25  IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[2]}]
set_property -dict {PACKAGE_PIN AE13 IOSTANDARD LVCMOS33} [get_ports {sfp_rs1[3]}]
```

> 若例程顶层已含 sfp 控制（部分 Aurora exdes 有 LED/控制引脚），以顶层端口名为准改 XDC 端口名，**别反向改语义**；top 里没输出就照 IBERT 的方式补端口 + assign（tx_disable=0 开激光，rs0/rs1=1 选 >4.25G 档）。

## 3. 流程骨架（7 步）

1. 新工程：`D:\FPGA\project_3`，名 **aurora_64b66b_loop**（part=`xcku060-ffva1156-2-i` 非 CIV）；之前 GT Wizard 误勾 X0Y3 的工程作废不管；
2. IP Catalog → **Aurora 64B/66B** → 按 §1 逐项配置 → Generate（等 OOC 综合完）；
3. 右键 IP → **Open IP Example Design**（选新目录）；
4. 检查例程：framing exdes **自带 frame_gen/frame_check**（无需 prbs_any/stimulus 补丁，比 GT Wizard 省事）；记下 refclk / init_clk / 用户数据端口名；
5. 按 §2 追加 XDC（顶层缺 sfp 控制端口则照 IBERT 方式补 3 输出 + assign）；
6. 综合 → 实现 → 位流；
7. 上板：断电接 **SFPA 单口自环** → 上电 → HW Manager 烧 bit → 打开 ILA。

## 4. 判据（全过才算成功）

- [ ] `channel_up` = 1（上电后等 1~2 秒：lane 初始化 → 对齐 → 验证块交换 → 通道建立）
- [ ] `lane_up[0]` = 1
- [ ] `hard_err` / `soft_err` / `frame_err` 全 = 0
- [ ] ILA：frame_gen 发的数据在 frame_check 侧匹配（good/匹配指示正常，数据持续变化）
- [ ] 佐证：用户时钟 ≈ 151.52 MHz（ILA 采样时钟/时钟报告可查）
- [ ] 截图归档 `D:\FPGA\aurora_loopback\docs\`

## 5. 坑位速查

| 症状                | 先查什么                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------- |
| refclk 下拉没有 T6/T5 | GT Location 选错了 quad——认 Bank 226 + Data pins R3/R4（同 GT Wizard 教训，手册旧编号 X0Y2=你的 X1Y2） |
| channel_up 一直 0   | 光纤自环没插好 / tx_disable 没拉低（XDC 生效否）；init clock 没接对（状态机没跑）；等足 2 秒再判                      |
| soft_err 持续出现     | 优先查光纤/速率一致性；极性 IBERT 已证 OK，别乱动反转选项                                                    |
| frame_err 有计数     | framing 对端帧序列不匹配——先确认两端都是同版本 core 的默认 CB/CC 序列                                        |
| 综合端口错误            | 顶层逗号陷阱 + XDC 端口名与顶层一致（IBERT 同款教训）                                                     |
| 例程被重生成覆盖          | 补丁永远做在新生成的 imports 文件里                                                                |
| 时钟约束缺失            | refclk 6.4ns + init_clk 10ns 两条 create_clock 都要有                                      |

## 6. 验证金字塔（答辩素材）

```
AXI-DMA/缓存转发  ← 系统层（M2 后半）
   ↑ 判据：数据吞吐与完整性
Aurora 64b/66b    ← 链路/协议层（本卡，当前步）
   ↑ 判据：channel_up / lane_up / 误码计数
IBERT             ← PMA/物理层 ✅（2026-08-27 达成）
   ↑ 判据：PLL Locked / Errors=0E0 / 眼图张开
```
每层判据独立、逐层归因：链路坏了先查下层，这就是"先 IBERT 后 Aurora"的方法论闭环。

---

*参谋位置：IP 配置页截图、例程顶层、报错——随时发。眼图截图（IBERT）归档别忘 `D:\FPGA\ibert_eye_test\docs\`。*
