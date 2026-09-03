# AGENTS.md — FPGA_Project 工程指令（开发层，工作区 D:\FPGA）

> 本文件是 Reasonix（VSCode ACP 开发层）的**常驻指令**，每次会话自动加载。
> 你是工程状态的**唯一事实源**（契约约定，见 vault `Agent 协作/开发协作文档.md`，用户转达）。
> vault 中枢 `Agent 协作/AI协作中枢.md` 是中控维护的同步视图，**可能滞后——以你实测为准**。

## 角色定位

你是毕设 FPGA 开发层的**执行 Agent**，工程状态的**唯一事实源**。三层分工 + 中控（契约：vault 开发协作文档）：
- **Reasonian（Obsidian）＝规划层/第二大脑**：管知识库、待办、方向、成果沉淀。vault 唯一写者。
- **你（VSCode）＝开发层**：管本工程。工程目录唯一写者。状态以你实测为准，主动如实汇报。
- **Reasonix（桌面端）＝协调中控**：任务路由、同步中枢↔本文件、状态看板、复杂任务/杂活兜底。你只需向用户汇报状态，同步由中控负责。
- **多会话约定**（中枢 §5.6，2026-08-07 立）：桌面端可能多会话并存，同一时间仅**一个活跃中控**（「协调中控」topic）；多个中控会话向你问状态时如实汇报即可，状态出入一律以你实测为准

## 硬红线（必须遵守）

1. **每步标注"为什么"**：用户答辩要讲得出原理，不允许只给结论不给解释
2. **物理层归用户**：上板、SFP+ 光纤插拔、ILA 抓波形、示波器——你只写操作清单，不代劳
3. **改动可追溯**：所有改动走 git（本工程已 git init），提交信息写清意图
4. **目录权限（2026-08-27 修订）**：本工程目录 `D:\FPGA\` 与 vault `C:\Users\15266\Desktop\毕设\` 已**双向开放**——vault 知识库现位于 Reasonian 会话工作目录内，Reasonian 可直接读写 vault 文档；经用户授权也可直接操作本工程目录（改源文件/XDC、跑批处理等，改动须可追溯）。本文件仍是工程侧唯一事实源；同步约定不变（中枢视图由中控维护）
5. **用户是 FPGA 新手**：遇到需要 GUI 理解的环节（第一次综合、看波形），明确提示用户去 GUI 看一遍建立直觉
6. **工程路径全英文**：Vivado 命令行对中文路径乱码（实测）

## 硬件与基线（不可改）

- **板卡**：Kintex UltraScale **XCKU060**（GTH 收发器、板载 DDR4 **4GB** = 4×MT40A512M16（8Gb x16/片，DDR4-2400 capable，64-bit 单 Rank，BANK 44/45/46；2026-08-31 丝印+拓扑图+原理图确认）、**无硬核 ARM**）
- **开发方案**：以 **MicroBlaze 软核**替代基线工程（ZCU102）的 PS 硬核
- **基线工程**：GitHub `FPGA-SFP-communication-with-Aurora`（DDR→DMA→Aurora 64b/66b→SFP+ 全链路）
- **应用场景**：多 Agent（树莓派/笔记本/服务器部署不同规模模型）经 FPGA 交换数据协同推理，参考 MoA 架构（ICLR 2025）
- **双工作模式**：缓存转发（先缓存后发） + 直通转发（交换功能）——导师会议确定

## 技术路线（5 阶段）

1. 软硬件协同流程（MicroBlaze 软核 + Vitis）← **当前**
2. AXI 总线族
3. DDR4/MIG
4. AXI DMA + 中断
5. Aurora/GTH（SFP 收发 + 64b/66b 编解码）

## 当前任务（2026-08-31，M2 进行中）

- 🎉 **Aurora 64b/66b 链路验证通过（2026-08-31）**——Aurora IP（v12.0，duplex/framing/单 lane/64-bit UI/QPLL1 FBDIV=64→10.000G 精确解，xci+生成 RTL 双重终验）例程上板：因实验室现有光纤接法为跨口互连（IBERT 四通道专用，单通道 duplex 不适用），采用**近端 PMA 内部串行环回**（`loopback_i=3'b010`），ILA 实测 `channel_up=1`、`lane_up=1`、`hard/soft_err=0`、`data_err_count=0`、`rx_tvalid=1`，板载状态灯 T22/T23（CHANNEL_UP/LANE_UP）点亮。物理层证据 = IBERT 外环真实光路（2026-08-27）；"Aurora 数据跑真实光纤"证据待联合调试阶段自然产生。工程留档：`D:\FPGA\aurora_64b66b_loop_ex\`（例程，exdes 补丁=LED T22/T23 + init_clk AK17/AK16 + 复位内部拉零 + sfp 版本 A 控制 + mark_debug×7）+ `D:\FPGA\project_3\`（IP 主工程）。实操单 = vault `操作文档/阶段二之三_Aurora64b66b环回实操单.md`。**下一步：AXI 总线族（design_1 活教材）→ Aurora framing 集成 → MIG/DDR4 → DMA → 联合调试**
- 🎉 **IBERT 光口物理链路自检通过（2026-08-27）**——FMC 四光口首口（SFPA）单口光纤自环，IBERT 10G PRBS 板级验证成功：**PLL Locked + Errors=0E0**。三项硬件事实就此定案（回填 vault 实操单）：
  1. **QUAD_226 = Quad X1Y2**（通道 X1Y8~Y11）——手册"X0Y2"系笔误，以实现落位报告为准；
  2. **光口参考时钟 = MGTREFCLK1_226（T6/T5）@156.25MHz**——CLK0(V6/V5) 不锁、CLK1 锁，实测+手册原文（"226_CLK1_P 对应光口外部输入时钟"）双重定案；
  3. **控制信号引脚 = 版本 A**（TX_DIS=H26/AH12/J25/AF12、RS0=G27/AH11/M26/AF13、RS1=H27/AG11/M25/AE13，索引 0~3=SFPD/B/C/A）——指南 XDC = 引脚表工作表1 = io_placed 报告三方一致。
  - 工程留档：例程工程 `D:\FPGA\ibert_ultrascale_gth_0\ibert_ultrascale_gth_0_ex\`（IBERT exdes，顶层含 sfp 控制补丁 + 版本 A XDC）；`project_2` 主工程可归档。眼图截图待归档 `ibert_eye_test\docs\`
  - ⏸️ **MIG/DDR4 搁置（2026-08-31 导师指示）**：位流已产出（`project_4`，含自研 AXI4 主机验证载体；DDR4 实况=4×MT40A512M16/4GB/DDR4-2400/BANK44-46）、定版卡完备，待解冻收尾（上板校准+比对）
  - ▶️ **当前步 = 阶段 2.5 上下位机+验证 SFP（UART 串口先行，路线图决策 #6）**：实操单 = vault `操作文档/阶段二之四_串口Aurora上下位机验证实操单.md`（自写 UART+帧适配+Aurora 内部环回；PC 侧三级验证）。之后：DMA 环回 → DMA↔Aurora 合体（真实光路证据在此产生）→ MicroBlaze 控制面；网口（双 RGMII，ATK91131A 座）推迟至多 Agent 联调前
- ⚠️ **命名陷阱存档（2026-08-26 实录）**：IBERT/GT IP 界面用 Bank 号（QUAD_226）称呼 Quad；XDC 里 `226_TX3_P` 之类标注 = Bank 226 的 GT 通道，≠"第 226 号 site"。选 quad 前先确认 site 名落位（X1Y*）再开跑
- 🎯 **阶段二（AXI 总线族）已启动（2026-08-12）**——里程碑口径沿用 vault：**M2 = SFP 收发+64b/66b 联调**，AXI 总线族是 M2 的前置阶段。目标：搞懂 MicroBlaze 的 AXI 接口与地址映射，能在 design_1 里对照实物讲解/修改总线结构。学习路线：① AXI4/AXI4-Lite/AXI4-Stream 三种协议 + 通道与 VALID/READY 握手 → ② 对照 design_1：microblaze_0 M_AXI_DP → axi_interconnect（地址译码）→ uartlite S_AXI（0x40600000）→ ③ 地址编辑器/软件读写寄存器验证 → ④ 动手实验：自定义 AXI-Lite IP（如 LED 寄存器）全流程走一遍。硬件侧流程不变（HW Manager 烧位流 + Vitis 取消 Program FPGA）
- 📌 **M2 前置资料已备（2026-08-12）**：FMC_4SFP 四光口 GTH 定位完成（见 `FMC_4SFP_GTH引脚表.md`）——4 口共用 **GT Quad X1Y2**（X1Y8~X1Y11），MGTREFCLK=**P6/P5**（GTHE3_COMMON_X1Y3）；⚠️ SFP_CLK 频率待查（10G 需 156.25MHz）、控制信号引脚两版冲突待确认（子卡在改）；官方 KU_IO.xdc 无 GT 内容
- 🎉 **里程碑 M1 达成（2026-08-11 晚）**：Vitis 导入硬件平台 → Hello World 串口打印成功（COM7@9600）。最终流程：Vivado 出 bitstream（part=`xcku060-ffva1156-2-i`）→ HW Manager 手动烧录 → Vitis 更新 XSA 硬件规格 + **Run Configuration 取消 Program FPGA 勾选**（保留 Reset entire system）→ Run（MDM 下载程序）
- 🧩 **M1 前全部故障根因复盘**：Vitis 报 `DONE PIN is not HIGH`（2023.1）/ `End of startup status: LOW`（2026.1）的**唯一根因 = part 选错**（`xcku060_CIV` 系学长教学视频参数，本板实物为非 CIV）。对照实验链：LED 冒烟（非 CIV part，成功）vs MicroBlaze（CIV part，失败）→ 位流头部 part 字段对比 → 定性。MODE=001、链路不稳、FT_Write=0 均为干扰项（次因/无关）。教训：教学视频参数 ≠ 实物，参数以实测为准

- ✅ Vivado/Vitis **2023.1** 已装：`D:\Xilinx\Vivado\2023.1` + `D:\Xilinx\Vitis\2023.1`（2026.1 已卸载，迁移依据见 `2026.1_工作交接文档.md`）
- ✅ License：**ENTERPRISE**，有效期至 **2026-10-05**（`%APPDATA%\XilinxLicense\Xilinx.lic`，无需环境变量）
- ✅ **板卡参数已确认**（2026-08-11 晚，实测修正）：
  - part = **`xcku060-ffva1156-2-i`（非 CIV 变体）**——铁证：CIV part 位流 Program 必报 startup LOW，非 CIV 位流成功且功能正常（LED 冒烟对照，2026-08-11 晚）；此前记录的 `xcku060_CIV` 为 2026.1 时代错误假设，**作废**（丝印核对无需再做，实测已定性）
  - 板载晶振 = **100MHz 差分**（与官方 `KU_IO.xdc` 第 5 行 `create_clock -period 10.000` 一致；旧默认"200MHz 单端"作废）
- ✅ **新 GUI 工程 `D:\FPGA\project_1`**（2026-08-11 建，Vivado 2023.1）：BD `design_1` = MicroBlaze 最小系统（Local Memory 64KB + AXI UART Lite **9600 波特率** + AXI Interconnect + MDM + clk_wiz 100MHz 差分输入 + rst_clk_wiz_1_100M）；**综合已通过**（0 错误，7 个 LMB/复位未连接类无害警告）
- ✅ 约束已进工程：`project_1/project_1.srcs/constrs_1/constraints/ku060_pins.xdc`（引脚取自官方 KU_IO.xdc：clk_p=AK17 差分、reset=AC34 低有效、uart=AE33/AF34，端口名已适配 wrapper；**2026-08-11 batch 验证已注册进 constrs_1，重跑综合 0 错误**；注释为纯英文 ASCII，中文在 Vivado 编辑器会 GBK 乱码）
- ✅ **git 已建立并推送**（2026-08-12）：`D:\FPGA` 重新 git init（master 分支），首次提交 M1 成果 + 合并远端 `chemmy-11/FPGA_Project`（私有）既有历史 → 推送成功（HEAD=e7ed594）。**`scripts/` Tcl 三件套从远端历史找回**（create_project/bd_mb_minimal/build/env_check.tcl，原以为丢失）。注意：git 全局代理 127.0.0.1:7897（Clash 类工具），代理未开时用 `git -c http.proxy= -c https.proxy=` 直连推送；凭据走系统 GCM
- ⚠️ `vivado_project/`（Tcl 骨架三件套）已移除且本地无历史，**但远端仓库保留**（scripts/ 已并入本仓库）——不再丢失
- ⛔ **原阻塞已突破（2026-08-11 晚）**：最小设计（led.v：按键取反→LED，无时钟无 IP）经 Vivado Hardware Manager Program **成功**（`xcku060 is programmed`）→ **JTAG 配置链路本身是好的**。MODE=001 理论**排除**（UG570 明文：JTAG 配置与 MODE 引脚选择无关；GPT 建议.md 亦确认）。根因方向 = **JTAG 链路/Vitis 调用路径**（偶发失败 + FT_Write=0 + 此前 Vitis Program 必败而 HW Manager 成功）。下一步：确认频率因素 → HW Manager 烧 project_1 bitstream → Vitis 取消 Program FPGA 勾选直接下载程序（MDM 路径）→ M1
- 📄 参考：`GPT建议.md`（外部 AI 诊断，2026-08-11 放根目录；含 UG570/UG908/UG912 引用与实验设计）
- ✅ **part 修正已验证**（2026-08-11 晚）：改 part 为 `xcku060-ffva1156-2-i`（非 CIV）重跑综合/实现/bitstream → **HW Manager 烧录成功**（`End of startup status: HIGH`）→ 原 CIV 假设彻底作废（源头：学长教学视频，非本板实物）
- ⏳ 待办（下一步）：
  1. M2 第一步：打开 design_1 的 Address Editor 与 AXI Interconnect，对照讲解 AXI 协议基础（详见"阶段二已启动"条）
  2. ✅ **FMC_4SFP 待查项①（2026-08-27 闭环）**：SFP_CLK = 156.25MHz 已确认（用户/黄工确认 + IBERT 上板 PLL Locked 实证）；时钟球对 = MGTREFCLK1_226（T6/T5）实测定案
  3. ✅ **FMC_4SFP 待查项②（2026-08-27 闭环）**：控制信号引脚定版 = 版本 A（工作表1），12 脚经指南 XDC/引脚表/实现落位报告三方核验一致；XDC 已进 IBERT 例程工程
  4. ⏭️ 8b/10b 环回实验（第 57 章）：实操单见 vault `操作文档/阶段二前置之二_8b10b环回实操单.md`
  5. 可选：`write_bd_tcl` 把 design_1.bd 固化成脚本（防工程丢失；Tcl 三件套已从远端找回，可参照改造）
- 🎯 里程碑 M1：Vitis 导入硬件平台，**Hello World 串口打印**
- 📚 参考（vault 内，用户转述）：`操作文档/阶段一_Vitis环境与MicroBlaze软核.md`（手把手教程）、`长期路线图_2026-08-31.md`（**整盘棋基准：原 5 阶段计划与实际执行的对账，含四处分歧决策记录**）、`8.3/2026-04-30/FPGA-SFP-communication-with-Aurora 项目详细介绍.md`（基线全貌）

## 工程结构

```
D:\FPGA\
├── project_1/             # Vivado 2023.1 GUI 工程（2026-08-11 建，当前事实源）
│   ├── project_1.xpr
│   ├── project_1.srcs/    # sources_1（BD design_1）+ constrs_1/constraints/ku060_pins.xdc
│   ├── project_1.runs/    # synth_1（完成）/ impl_1（待跑）
│   └── project_1.gen/     # 生成物（wrapper、IP 网表）
├── KU_IO.xdc              # 官方板卡 IO 引脚表（GBK 编码；时钟 100MHz 差分 AK17、复位 AC34、UART AE33/AF34）
├── KU引脚表.xlsx
├── test/                  # 旧测试工程（2026-08-07，已废弃）
└── *.md                   # 交接/协作文档（2026.1_工作交接文档.md 等）
```

- `vivado_project/`、`vitis_project/` 已移除（2026-08-11 前）；Vitis 阶段工作区届时 GUI 新建即可

## 常用命令（Windows）

```bash
"D:\Xilinx\Vivado\2023.1\bin\vivado.bat" D:\FPGA\project_1\project_1.xpr   # 打开工程（GUI）
"D:\Xilinx\Vitis\2023.1\bin\vitis.bat"                                     # Vitis（工作区 GUI 新建）
```

## 同步约定

- 本文件 = 工程侧**唯一**执行版；vault `Agent 协作/AI协作中枢.md` = 中控维护的**状态视图**（可能滞后，以你实测为准）
- 协作契约 = vault `Agent 协作/开发协作文档.md`（四方模型、事实源、柔性边界；变更由用户转达）
- **工程内不维护 vault 文档副本**（`docs/` 已于 2026-08 移除）：需要什么信息直接更新本文件，参考文档一律回 vault 查（`毕设\` 下：短期待办、操作文档、8.3 会议纪要等），由用户转达或中控同步要点
- **工程状态变化** → 你更新本文件"当前任务"节，并向用户报告一句"状态已更新"；**中枢同步由协调中控（桌面端 Reasonix）负责，你无需跨目录操作**
- **中枢/规划变更** → 协调中控会同步到本文件，新会话自动加载
- 两边不一致时，向用户确认后以中枢为准
